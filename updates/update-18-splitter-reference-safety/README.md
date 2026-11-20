# Update 18: Splitter reference safety

- Splitters now store conveyor instance IDs instead of object references for their inputs and outputs.
- Item routing resolves active conveyor segments by ID, so demolished or freed belt segments are skipped safely.
