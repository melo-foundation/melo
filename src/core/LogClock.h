#pragma once

#include <chrono>

// One clock for every timing marker: a function-local static in an inline
// header function has one instance program-wide, so PlaybackCoordinator,
// SourceDeck and SidecarProcess timestamps share t0. A per-.cpp copy would not.
inline double meloLogMs() {
    using clk = std::chrono::steady_clock;
    static const clk::time_point t0 = clk::now();
    return std::chrono::duration<double, std::milli>(clk::now() - t0).count();
}
