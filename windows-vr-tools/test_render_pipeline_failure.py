#!/usr/bin/env python3
"""Execute production D3D11 submission callbacks against a failing async PSO.

Uses the applied profile source, not a duplicate guard implementation. No Wine
or graphics driver is needed for the immediate/deferred ordering regression.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=Path, required=True, help='Applied DXMT source tree')
a = p.parse_args()
s = (a.source / 'src/d3d11/d3d11_context_impl.cpp').read_text()

def block_at(start):
    first = s.index('{', start)
    depth = 1
    end = first + 1
    while depth:
        depth += (s[end] == '{') - (s[end] == '}')
        end += 1
    return s[start:end]

start = s.index('  template <CommandWithContext<ArgumentEncodingContext> cmd>\n  void EmitDraw(')
guard = block_at(start)
start = s.index('    EmitST([pso = std::move(pipeline), foveationSafe, stereoPipeline]')
bind = block_at(start) + ');'
program = r'''
#include <cassert>
#include <cstdint>
#include <functional>
#include <utility>
#include <vector>
struct MTL_COMPILED_GRAPHICS_PIPELINE { uintptr_t PipelineState = 0; };
struct Pipeline {
  uintptr_t value;
  void GetPipeline(MTL_COMPILED_GRAPHICS_PIPELINE *out) { out->PipelineState = value; }
};
struct wmtcmd_render_setpso { int type = 0; uintptr_t pso = 0, stereo_pso = 0; };
constexpr int WMTRenderCommandSetPSO = 1;
struct ArgumentEncodingContext {
  struct Encoder { uintptr_t last_pso = 0; bool foveation_safe = true; } encoder;
  std::vector<wmtcmd_render_setpso> commands;
  Encoder *currentRenderEncoder() { return &encoder; }
  template<typename T> T &encodeRenderCommand() { return commands.emplace_back(); }
};
template<typename T, typename Context>
concept CommandWithContext = requires(T &fn, Context &enc) { fn(enc); };
struct Context {
  bool immediate;
  ArgumentEncodingContext enc;
  std::vector<std::function<void(ArgumentEncodingContext&)>> pending;
  template<typename F> void EmitOP(F &&fn) {
    if (immediate) fn(enc);
    else pending.emplace_back(std::forward<F>(fn));
  }
  template<typename F> void EmitST(F &&fn) { EmitOP(std::forward<F>(fn)); }
  GUARD
  void Bind(Pipeline *pipeline) {
    bool foveationSafe = true;
    Pipeline *stereoPipeline = nullptr;
    BIND
  }
  void Flush() { for (auto &fn : pending) fn(enc); pending.clear(); }
};
int main() {
  for (bool immediate : {true, false}) {
    Context ctx{immediate};
    Pipeline valid{0x100}, rejected{0}, recovered{0x200};
    std::vector<uintptr_t> draws;
    auto draw = [&](ArgumentEncodingContext &enc) { draws.push_back(enc.encoder.last_pso); };
    // Includes the original title-crash case, then recovery, then the stale-PSO case.
    ctx.Bind(&rejected); ctx.EmitDraw(draw);
    ctx.Bind(&valid); ctx.EmitDraw(draw);
    ctx.Bind(&rejected); ctx.EmitDraw(draw);
    ctx.Bind(&rejected); ctx.EmitDraw(draw);
    ctx.Bind(&recovered); ctx.EmitDraw(draw);
    if (!immediate) assert(draws.empty());
    ctx.Flush();
    assert((draws == std::vector<uintptr_t>{0x100, 0x200}));
    assert(ctx.enc.commands.size() == 2);
    assert(ctx.enc.encoder.last_pso == recovered.value);
    ctx.Bind(&rejected); ctx.Flush();
    assert(ctx.enc.encoder.last_pso == 0);
  }
}
'''.replace('GUARD', guard).replace('BIND', bind)
with tempfile.TemporaryDirectory() as d:
    src = Path(d) / 'probe.cpp'
    exe = Path(d) / 'probe'
    src.write_text(program)
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-fsanitize=address,undefined',
                    '-fno-omit-frame-pointer', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: production submission callbacks reject absent/failed PSOs, invalidate stale bindings, and recover on valid PSOs (immediate/deferred; ASan/UBSan)')
