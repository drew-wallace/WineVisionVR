#!/usr/bin/env python3
"""Exercise the prepared production scheduler with portable host thread primitives."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-source", type=Path, required=True)
    args = parser.parse_args()
    header = args.runtime_source.resolve() / "dxmt/src/dxmt/dxmt_tasks.hpp"
    if not header.is_file():
        parser.error("Prepare the modern DXMT source profile first")
    with tempfile.TemporaryDirectory(prefix="wvr-dxmt-scheduler-") as work:
        work = Path(work)
        (work / "thread.hpp").write_text("""
#include <thread>
#include <mutex>
#include <condition_variable>
#include <vector>
namespace dxmt { using thread = std::thread; using mutex = std::mutex;
using condition_variable = std::condition_variable; }
""")
        (work / "util_win32_compat.h").write_text("""
#define THREAD_PRIORITY_TIME_CRITICAL 0
inline int GetCurrentThread() { return 0; }
inline void SetThreadPriority(int, int) {}
""")
        (work / "main.cpp").write_text(r'''
#include <cassert>
#include <future>
#include "dxmt_tasks.hpp"
struct Job {
    std::promise<void> started;
    std::shared_future<void> release;
    std::atomic<bool> done{false};
};
namespace dxmt {
template <> struct task_trait<Job *> {
    Job *run_task(Job *job) { job->started.set_value(); job->release.wait(); return job; }
    bool get_done(Job *job) { return job->done.load(); }
    void set_done(Job *job) { job->done.store(true); }
};
}
int main() {
    using namespace std::chrono_literals;
    // A running compile must finish before shutdown returns and its owner can
    // release shader/device data. No sleep is used to start the worker.
    std::promise<void> gate;
    Job job;
    job.release = gate.get_future().share();
    {
        dxmt::task_scheduler<Job *> scheduler;
        scheduler.submit(&job);
        job.started.get_future().wait();
        std::promise<void> stopping;
        auto finished = std::async(std::launch::async, [&]() {
            stopping.set_value(); scheduler.shutdown();
        });
        stopping.get_future().wait();
        assert(finished.wait_for(20ms) == std::future_status::timeout);
        gate.set_value();
        assert(finished.wait_for(5s) == std::future_status::ready);
        finished.get();
        assert(job.done && scheduler.get_running_threads() == 0);
        scheduler.shutdown(); // The later destructor must also be safe.
    }
    // Exercise the idle-worker wait/notification boundary repeatedly.
    for (int i = 0; i < 500; ++i) {
        dxmt::task_scheduler<Job *> scheduler;
        scheduler.shutdown();
    }
}
''')
        subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-I", str(work), "-I", str(header.parent),
                        str(work / "main.cpp"), "-o", str(work / "probe")], check=True)
        subprocess.run([str(work / "probe")], check=True, timeout=30)
    print("PASS: in-flight work joined before release, repeat shutdown, 500 idle shutdowns; ASan/UBSan")


if __name__ == "__main__":
    main()
