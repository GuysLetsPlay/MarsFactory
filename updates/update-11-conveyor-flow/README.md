# Update 11: Connected conveyor production

- Dust extractors only produce a visible dust item when a conveyor starts at their outlet.
- Items move along a conveyor run and transfer to the next segment when its start touches the previous segment's end.
- Conveyor runs can be continued or turned by starting the next run at an existing run's endpoint.
- Dust presses consume items that arrive at their intake and increment the pressed-dust count.
- The placement preview checks the full route and estimates its total cost.
