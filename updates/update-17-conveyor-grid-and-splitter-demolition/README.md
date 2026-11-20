# Update 17: Conveyor grid and splitter demolition

- Free conveyor endpoints now use the same 2 m grid as building placement.
- Belts started from machine outlets or existing belt exits keep their source direction, which keeps matching runs parallel.
- Splitters now have a selectable collider and can be dismantled with `X` or from their building UI.
- Dismantling a splitter removes its branch and restores a continuous straight conveyor; the splitter itself has no refund because it was auto-placed for free.
- Removed stale splitter-output references from item routing.
