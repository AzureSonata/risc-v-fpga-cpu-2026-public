#!/usr/bin/env python3
"""Build pinned CoreMark through Ubuntu WSL for RV32I, Zmmul, or M."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIN = '1f483d5b8316753a742cbf5590caf5bd0a4e4777'

def linux(path):
    p = Path(path).resolve().as_posix()
    return '/mnt/'+p[0].lower()+p[2:]

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--iterations', type=int, required=True)
    p.add_argument('--mode', choices=('performance','validation'), default='performance')
    p.add_argument('--march', choices=('rv32i', 'rv32i_zmmul', 'rv32im',
                                       'rv32i_zicsr', 'rv32i_zicsr_zmmul', 'rv32im_zicsr'), required=True,
                   help='Legacy spellings are accepted as aliases; all new CoreMark ports enable Zicsr for 64-bit mcycle timing')
    p.add_argument('--timer-hz', '--cpu-hz', dest='timer_hz', type=int, default=100058824,
                   help='Timer frequency embedded in firmware metadata (default: 63/17 PLL from 27 MHz)')
    p.add_argument('--upstream', type=Path,
                   help='Pinned CoreMark source tree; must match SOURCE_MANIFEST.json')
    p.add_argument('--toolchain', default=os.environ.get('RISCV32_TOOLCHAIN_PREFIX', 'riscv32-unknown-elf-'))
    p.add_argument('--out-dir', type=Path, help='Explicit artifact directory (must be empty unless --overwrite)')
    p.add_argument('--overwrite', action='store_true', help='Explicitly replace files in a prior firmware build directory')
    p.add_argument('--optimization', choices=('O2', 'O3'), default='O2',
                   help='Default O2 is the fixed architectural acceptance profile; O3 is a separate comparison')
    a = p.parse_args()
    if a.timer_hz <= 0:
        p.error('timer-hz must be positive')
    if a.iterations <= 0:
        p.error('iterations must be positive')
    upstream = a.upstream.resolve() if a.upstream else ROOT/'build/coremark-upstream'/PIN
    if not upstream.exists():
        p.error(f'Pinned CoreMark source not found: {upstream}')
    manifest = json.loads((upstream/'SOURCE_MANIFEST.json').read_text(encoding='utf-8'))
    for entry in manifest['files']:
        if hashlib.sha256((upstream/entry['path']).read_bytes()).hexdigest() != entry['sha256']:
            raise RuntimeError('Modified upstream: '+entry['path'])
    march_aliases = {'rv32i': 'rv32i_zicsr', 'rv32i_zmmul': 'rv32i_zicsr_zmmul',
                     'rv32im': 'rv32im_zicsr'}
    march = march_aliases.get(a.march, a.march)
    out = (a.out_dir or (ROOT/'build/coremark'/f'{a.mode}-i{a.iterations}-{march}')).resolve()
    if out.exists() and not out.is_dir():
        p.error(f'Output path is not a directory: {out}')
    if out.exists() and any(out.iterdir()) and not a.overwrite:
        p.error(f'Output directory is not empty: {out}; choose a fresh --out-dir or explicit --overwrite')
    if a.overwrite and out.exists():
        # Remove old candidate markers/artifacts before doing any work so a
        # failed rebuild cannot leave a stale manifest that appears current.
        for name in ('manifest.json', 'coremark.elf', 'coremark.bin', 'coremark.hex',
                     'coremark.map', 'coremark.dis', 'size.log', 'toolchain-version.log',
                     'build.log', 'objcopy.log', 'elf-attributes.log'):
            stale = out / name
            if stale.is_file() or stale.is_symlink():
                stale.unlink()
    out.mkdir(parents=True, exist_ok=True)
    port = ROOT/'firmware/coremark/port'
    common = ['-'+a.optimization,'-march='+march,'-mabi=ilp32','-msmall-data-limit=0','-mstrict-align','-fno-builtin',
              '-ffreestanding','-fno-common','-ffunction-sections','-fdata-sections']
    args = common+['-std=c11','-Wall','-Wextra','-I'+linux(port),'-I'+linux(upstream),
        '-D'+a.mode.upper()+'_RUN=1',f'-DITERATIONS={a.iterations}',f'-DTIMER_HZ={a.timer_hz}','-DTOTAL_DATA_SIZE=2000',
        '-DFLAGS_STR="'+' '.join(common)+'"']
    args += [linux(upstream/n) for n in ('core_list_join.c','core_main.c','core_matrix.c','core_state.c','core_util.c')]
    args += [linux(port/n) for n in ('core_portme.c','ee_printf.c','start.S')]
    args += ['-nostdlib','-Wl,--gc-sections','-Wl,-Map,'+linux(out/'coremark.map'),'-T'+linux(port/'link.ld'),
        '-Wl,--defsym,ROM_BYTES=65536','-Wl,--defsym,RAM_BYTES=65536','-Wl,--defsym,STACK_BYTES=4096',
        '-lgcc','-o',linux(out/'coremark.elf')]
    commands = []
    def run(tool, args, filename):
        cmd = ['wsl.exe','-d','Ubuntu','--',a.toolchain+tool]+args
        commands.append(cmd)
        r = subprocess.run(cmd,capture_output=True)
        (out/filename).write_bytes(r.stdout+r.stderr)
        if r.returncode:
            print((r.stdout+r.stderr).decode('utf8',errors='replace'))
            raise RuntimeError(tool+' failed')
        return r.stdout
    compiler_version = run('gcc',['--version'],'toolchain-version.log').decode('utf-8', errors='replace').splitlines()[0]
    run('gcc',args,'build.log')
    run('objcopy',['-O','binary',linux(out/'coremark.elf'),linux(out/'coremark.bin')],'objcopy.log')
    # Tool output contains the user-selected Unicode workspace path.
    size = run('size',[linux(out/'coremark.elf')],'size.log').decode('utf-8')
    disasm = run('objdump',['-d',linux(out/'coremark.elf')],'coremark.dis')
    attributes = run('readelf',['-h','-A',linux(out/'coremark.elf')],'elf-attributes.log').decode('utf-8')
    arch_line = next((line for line in attributes.splitlines() if 'Tag_RISCV_arch:' in line), '')
    required = {'rv32i_zicsr': ('zicsr2p0' in arch_line and 'm2p0' not in arch_line and 'zmmul1p0' not in arch_line),
                'rv32i_zicsr_zmmul': ('zicsr2p0' in arch_line and 'zmmul1p0' in arch_line and 'm2p0' not in arch_line),
                # GCC's canonical Tag_RISCV_arch also lists Zmmul when M is
                # present, because M includes the multiply subset.
                'rv32im_zicsr': ('zicsr2p0' in arch_line and 'm2p0' in arch_line)}[march]
    if 'rv32i2p1' not in arch_line or 'RVC' in attributes or not required:
        raise RuntimeError('ELF attributes do not match requested non-compressed ISA')
    data = (out/'coremark.bin').read_bytes()
    if len(data)>65536:
        raise RuntimeError('ROM overflow')
    padded = data+b'\0'*((-len(data))%4)
    words = [int.from_bytes(padded[i:i+4],'little') for i in range(0,len(padded),4)]
    words += [0x13]*(16384-len(words))
    (out/'coremark.hex').write_text(''.join(f'{w:08x}\n' for w in words),encoding='ascii')
    result = {'upstream_commit':PIN,'mode':a.mode,'march':march,'iterations':a.iterations,'timer_hz':a.timer_hz,
        'timer_bits':64,'rom_bytes':65536,'ram_bytes':65536,'stack_bytes':4096,'binary_bytes':len(data),'hex_words':len(words),
        'optimization':a.optimization,'compiler_flags':common,'compiler_version':compiler_version,
        'upstream_manifest_sha256':hashlib.sha256((upstream/'SOURCE_MANIFEST.json').read_bytes()).hexdigest(),
        'port_sha256':{n:hashlib.sha256((port/n).read_bytes()).hexdigest() for n in ('core_portme.c','core_portme.h','ee_printf.c','start.S','link.ld')},
        'commands':commands,'files':{f:hashlib.sha256((out/f).read_bytes()).hexdigest() for f in ('coremark.elf','coremark.bin','coremark.hex')},
        'physical_score':'NOT_RUN'}
    (out/'manifest.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf8')
    print(size,end='')
    print(out/'coremark.hex')

if __name__=='__main__':
    main()
