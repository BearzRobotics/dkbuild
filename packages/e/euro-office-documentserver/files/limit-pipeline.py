# Caps how many tasks of a phase run at once in web-apps/build/scripts/build-pipeline.js (env PIPELINE_JOBS; unset: all at once, as upstream).
# Phase 1 starts six webpack builds and four mobile builds together; each is a few GB of Node heap, and the build died there without a message.
import sys
p = sys.argv[1]
s = open(p).read()
old = "    const running = taskSpecs.map(runTask);\n"
assert old in s, "build-pipeline.js: the phase() line was not found"
new = """    // FenrirOS: at most PIPELINE_JOBS tasks at a time (default: all)
    let slots = Math.max(1, parseInt(process.env.PIPELINE_JOBS || '0', 10) || taskSpecs.length);
    const waiters = [];
    const acquire = () => slots > 0 ? (slots--, Promise.resolve()) : new Promise(r => waiters.push(r));
    const release = () => { const w = waiters.shift(); if (w) w(); else slots++; };
    const running = taskSpecs.map(spec => {
        let inner = null, killed = false;
        const promise = acquire().then(() => {
            if (killed) return { label: spec.label, ms: 0, code: -1 };
            inner = runTask(spec);
            return inner.promise;
        }).finally(release);
        return { promise, kill: () => { killed = true; if (inner) inner.kill(); }, label: spec.label };
    });
"""
s = s.replace(old, new, 1)
open(p, 'w').write(s)
