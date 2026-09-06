# ReaScript behaviour, verified empirically

Facts the ReaScript documentation does not state, established by running
`tools/probe_peaks.lua` against a real project. The REAPER adapter depends on
all of them.

**Environment:** REAPER 7.42.0, macOS 26.6.2 arm64, 2026-09-06.

## REAPER's embedded Lua is 5.4

`_VERSION` reports `Lua 5.4`. This confirms the project's version pinning:
`bin/test` runs the suite on Homebrew's `lua@5.4`, not the default `lua`
(5.5.1), so tests execute on the same interpreter REAPER does.

## `GetMediaItemTake_Peaks`'s `starttime` is PROJECT time

Not source time, and not item-relative time. This is the finding that matters
most, because the documentation is silent and the two wrong answers fail
silently rather than loudly.

Probed against an item at project position `211353.345`, length `492.335`,
`D_STARTOFFS = 0`, one channel, reading 40 frames at 20 Hz from the item's
midpoint:

| Interpretation | `starttime` passed | Non-silent frames | Peak |
|---|---|---|---|
| source time (`startoffs + mid`) | `246.168` | 0 of 40 | 0.00000 |
| item-relative (`mid`) | `246.168` | 0 of 40 | 0.00000 |
| **project time (`item pos + mid`)** | `211599.513` | **40 of 40** | **0.35437** |

The item's large timeline offset is what makes this unambiguous: the three
hypotheses are separated by 58 hours, so only one can land on audio. An item
near position zero would have produced three similar-looking reads and proved
nothing.

**Consequence for the adapter:** pass the absolute project time directly. Do
not add `D_STARTOFFS`, and do not convert to source time. `D_PLAYRATE` also
needs no compensation, since a project-time read already reflects the take as
placed on the timeline.

## Reading outside an item returns silence, not an error

In the two failing rows above, the call did not error and did not return a
short read. It returned the full 40 requested frames, every value `0.0000`,
with `retval = 0x28` (40 in the low 20 bits) exactly as in the successful read.

**A read outside an item's media is indistinguishable from a read of a silent
room.** The adapter therefore cannot use this call to discover where media
exists; it must clamp every read to item extents obtained from
`GetMediaItemInfo_Value`, and leave all other frame positions `false`.

This is the empirical basis for the project-wide invariant that absence is
`false` and never `0`: if out-of-item reads were allowed to write zeros into a
frame array, every per-track noise floor computed over them would be dragged
toward silence, and hard cuts would become indistinguishable from quiet
passages.

## Buffer layout is maximums, then minimums

Confirmed at the winning position, channel 1, first 8 frames:

| frame | block 1 | block 2 |
|---|---|---|
| 1 | 0.15360 | −0.20325 |
| 2 | 0.16175 | −0.18707 |
| 3 | 0.07828 | −0.13086 |
| 4 | 0.28971 | −0.26489 |

Block 1 was never below block 2 in any sampled frame. Block 1 holds maximums,
block 2 holds minimums, matching the documented "two or three blocks
(maximums, then minimums, then extra)". With `want_extra_type = 0` there are
two blocks, so the buffer must be sized `channels * numsamplesperchannel * 2`,
and block 2 begins at offset `returned * channels`.

## Return value decoding

`retval = 0x28` for a 40-frame request. The documented packing holds:

- returned sample count: `retval & 0xfffff` → 40
- output mode: `(retval & 0xf00000) >> 20` → 0
- extra-type-available bit: `retval & 0x1000000` → 0

The count returned equalled the count requested. Behaviour when a read runs
past the end of available media was not exercised here, since the successful
read landed mid-item; the adapter should still treat `returned < requested` as
normal and fill only the frames actually returned.
