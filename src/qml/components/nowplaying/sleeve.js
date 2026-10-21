.pragma library

// How far the record is out of its sleeve: from halfway to the record stop, and
// back in over the first 30% of the leg to the classic page.
function emerge(p, q) {
    return Math.max(0, (p - 0.5) / 0.5) * Math.max(0, 1 - q / 0.3)
}

// The sleeve's opacity: glass over video (videoIn 1) on the poster face, solid
// by halfway to the record stop, before the record inside it shows.
function cover(p, videoIn) {
    return 1 - videoIn * (1 - Math.min(1, p * 2))
}
