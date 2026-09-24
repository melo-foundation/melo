import QtQuick
import QtTest
import "../../src/qml/components/skeletonmodel.js" as Flow

// Algorithmic test of the skeleton loading flow. Seeded placeholder counts
// never match page sizes, so trimming after each batch would remove visible
// rows and re-add them; the flow consumes placeholders across batches and
// shrinks the model at most ONCE, at the very end.
Item {
    ListModel { id: m }

    function realCount() {
        let n = 0
        for (let i = 0; i < m.count; i++) if (m.get(i).placeholder !== true) n++
        return n
    }

    TestCase {
        name: "LoadFlow"

        function rows(n, prefix) {
            const out = []
            for (let i = 0; i < n; i++)
                out.push({ id: prefix + i, title: "t" + i, channel: "c",
                           duration: 60, thumbnail: "" })
            return out
        }

        // A big window seeds 25, pages return 20.
        function test_a_mismatch_never_shrinks_midflow() {
            const st = Flow.beginLoad(m, 25)
            compare(m.count, 25)

            // page 1: 20 of 25 placeholders consumed; NOTHING removed
            let wantMore = Flow.acceptBatch(m, st, rows(20, "a"), true)
            compare(m.count, 25)                 // count unchanged — no visible correction
            compare(realCount(), 20)
            compare(Flow.placeholdersLeft(m, st), 5)
            verify(wantMore, "5 placeholders remain + source has more -> fetch")

            // page 2: fills the 5, appends 15
            wantMore = Flow.acceptBatch(m, st, rows(20, "b"), true)
            compare(m.count, 40)                 // grew, never shrank
            compare(realCount(), 40)
            verify(!wantMore, "no placeholders left -> normal pagination takes over")
        }

        // Source runs dry while placeholders remain: exactly one trim.
        function test_b_exhaustion_trims_once() {
            const st = Flow.beginLoad(m, 25)
            Flow.acceptBatch(m, st, rows(20, "a"), true)
            compare(m.count, 25)
            const wantMore = Flow.acceptBatch(m, st, rows(3, "b"), false)
            compare(m.count, 23)                 // single final correction
            compare(realCount(), 23)
            verify(!wantMore)
        }

        // Small window: fewer placeholders than the page — batch overflows.
        function test_c_small_window_overflow_appends() {
            const st = Flow.beginLoad(m, 8)
            const wantMore = Flow.acceptBatch(m, st, rows(20, "a"), true)
            compare(m.count, 20)
            compare(realCount(), 20)
            verify(!wantMore, "no placeholders left")
        }

        // Zero results with no more pages: placeholders all trimmed.
        function test_d_no_results() {
            const st = Flow.beginLoad(m, 12)
            const wantMore = Flow.acceptBatch(m, st, [], false)
            compare(m.count, 0)
            verify(!wantMore)
        }

        // Pagination: placeholders appended AFTER existing rows are consumed
        // by the next batch; existing rows are untouched; over-fill appends.
        function test_f_pagination_append_flow() {
            let st = Flow.beginLoad(m, 20)
            Flow.acceptBatch(m, st, rows(20, "a"), true)
            compare(m.count, 20)

            // grid case: 20 items, 3 cols -> tail = 1 (complete row) + 3
            st = Flow.beginAppend(m, 4)
            compare(m.count, 24)
            compare(realCount(), 20)
            const wantMore = Flow.acceptBatch(m, st, rows(20, "b"), true)
            compare(m.count, 40)      // 4 consumed in place + 16 appended
            compare(realCount(), 40)
            verify(!wantMore)
        }

        // Pagination failure: only the appended tail is removed.
        function test_g_pagination_failure_removes_tail_only() {
            let st = Flow.beginLoad(m, 10)
            Flow.acceptBatch(m, st, rows(10, "a"), true)
            st = Flow.beginAppend(m, 4)
            compare(m.count, 14)
            Flow.acceptBatch(m, st, [], false)
            compare(m.count, 10)
            compare(realCount(), 10)
        }

        // Grid counts must ALWAYS be multiples of the column count — a
        // partial skeleton row reads as a broken grid.
        function test_h_grid_counts_complete_rows() {
            for (let w = 200; w <= 2600; w += 97) {
                const cols = Flow.gridCols(w)
                for (let h = 100; h <= 1600; h += 217) {
                    const n = Flow.fillCount("grid", w, h)
                    compare(n % cols, 0, "fillCount " + n + " @ " + w + "x" + h
                            + " not a multiple of " + cols)
                }
                for (let count = 0; count < 47; count++) {
                    const tail = Flow.paginationTail("grid", w, count)
                    verify(tail >= cols, "tail at least one full row")
                    compare((count + tail) % cols, 0,
                            "count " + count + " + tail " + tail + " must land on a row boundary")
                }
            }
        }

        // Multi-page chain: count is monotonically non-decreasing until the
        // final batch.
        function test_e_monotonic_growth() {
            const st = Flow.beginLoad(m, 30)
            let minSeen = m.count
            const batches = [12, 9, 14, 11]
            for (let i = 0; i < batches.length; i++) {
                Flow.acceptBatch(m, st, rows(batches[i], "p" + i), true)
                verify(m.count >= minSeen, "count never shrank: " + m.count)
                minSeen = m.count
            }
            Flow.acceptBatch(m, st, rows(2, "last"), false)
            compare(realCount(), 12 + 9 + 14 + 11 + 2)
            compare(m.count, realCount())
        }
    }
}
