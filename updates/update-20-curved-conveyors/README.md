# Update 20: Curved conveyors

- Conveyor routes between snapped machine and belt ports can now use a smooth, sampled curve that honors the direction of each port.
- Curves are built from short tangent-aligned conveyor sections, so items follow the bend and continue across each section.
- The placement preview follows the curved route, and route cost uses its measured length.
- Source runs remain parallel at their machine outlets before bending toward their destinations.
- Removed the build menu's invalid automatic focus request that produced repeated Godot warnings.
