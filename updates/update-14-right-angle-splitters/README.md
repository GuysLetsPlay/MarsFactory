# Update 14: Right-angle conveyor splitters

## What changed

- Starting a conveyor run on an existing belt now anchors the start to the belt centerline, so it stays fixed while aiming.
- The new branch is constrained to exactly 90 degrees from the existing belt.
- The existing segment is split at the attachment point and a three-way splitter is placed automatically.
- Splitter visuals use a steel junction body with marked input and output lanes.
- Items alternate between the straight belt and the branch. If both outputs are occupied, the input belt queues items until an output has room.

## How to use it

Select a conveyor, click on the middle of an existing belt, aim sideways, then click again to build the branch.
