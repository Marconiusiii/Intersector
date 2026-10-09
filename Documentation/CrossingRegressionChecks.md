# Crossing interpretation checks

The phone and Watch use actual shared OpenStreetMap road nodes to identify crossings. Point and path representations produce the same `crossing-<node ID>` identity and use the same suppression rules. No nearby-road fallback or average path coordinate is used. A path crossing multiple roads can supply separate candidates at each actual road connection. Incomplete map connectivity is omitted rather than assigned to a nearby street.

## Riverside Drive replay

`crossStreetTests/Fixtures/CrossingRegression.json` includes a public OpenStreetMap response fetched on October 8, 2026, with source timestamp `2026-10-08T20:56:51Z`. Data is © OpenStreetMap contributors, available under the [Open Database License](https://www.openstreetmap.org/copyright).

The bounded discovery query selected Riverside Drive ways in `(40.790,-73.985,40.810,-73.965)`, highway ways and crossing-tagged points within 25 metres of their nodes, and the selected ways' complete node geometry. Complete ways can extend beyond that bounding box. The regression assertion covers Riverside Drive candidates within `(40.7975,-73.975,40.801,-73.971)`; surrounding records remain in the fixture to preserve road-junction context.

The original production Watch parser emitted both point and path candidates for these connections:

- Node 2329798629 and way 224147617, near West 99th Street.
- Node 2997576815 and way 5671536, near West 100th Street.
- Node 6912871504 and way 738265087, near West 101st Street.

Each now yields one candidate at the road node. Way 735025394 near West 103rd Street previously produced an extra candidate after the existing corner rules suppressed its two road crossing nodes, 7785881402 and 7785782261. The path no longer bypasses those rules.

No `crossing=no` records were present in this downloaded sample. The negative-tag bug is covered separately with constructed fixtures. The replay establishes candidate-generation errors, not which result the user heard or physical curb accuracy.

## Automated coverage

The same 18 fixtures run against the production phone and Watch builders, with Walking Paths on and off, through direct loading, enrichment, and repeated enrichment. They check crossing identities, counts, road association, coordinates, and signal details. Cases include explicit negative tags, valid unmarked crossings, point/path duplicates, split paths, displaced path averages, nearby orphan points, parallel paths, grade-separated geometry without a shared road node, ordinary junctions, multiple-road crossings, and the real Riverside response.

An additional 24 shared detail fixtures check audible walk signals versus locator-only tones, contradictory point/path tags, islands, and exact-node intersection enrichment. Both parsers run each case through direct loading, enrichment, and repeated enrichment, with path order reversed. Full announcement checks cover Intersection Details on and off and verify that audible pedestrian signals replace the generic signal phrase. Nearby suppressed crossings do not supply details to an intersection by proximity.

Run the phone `CrossingRegressionTests` and `IntersectionDetailTests` suites with Xcode. Run Watch checks from the repository root with:

```sh
python3 Tools/WatchUpcomingChecks/run-crossing-checks.py
```

The Watch runner compiles the production service with only sensor acquisition stubbed; it does not use live networking or device location. Existing tests continue to cover ordinary crossings, Columbus Avenue-style connected crossing paths, service-road exclusions, and corner suppression.

## Device checks

With Crossings enabled, revisit the affected Riverside Drive route using Nearest, Upcoming, and Walking Live on the phone and Watch. Check that a crossing is identified once at the correct road connection, and that ordinary intersection announcements are not followed by an extra crossing for the same corner. Also verify that an actual midblock crossing is retained. Physical location, speech timing, and map accuracy still require this field check.
