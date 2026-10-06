# Map-loading reliability review

## Scope

Phone app startup and intersection requests, phone Live, built-in Siri intersection actions, structured Get actions, and Watch app/Siri requests. Saved-area downloads remain deferred.

## Recovery correction after tester regression reports

The divided server allowance introduced a regression risk: a primary request received only six seconds with the full old budget, or 3.6 seconds after eight seconds of location acquisition. Local timeouts also excluded endpoints from the next request for a minute. The tests had verified those timing rules without testing valid responses arriving later.

The recovery restores up to 12 seconds for each server, independent of fallback count. The overall request limit is now 60 seconds so location acquisition and fallback requests have time to finish. The remaining overall deadline can still shorten an attempt near that limit. Local timeouts no longer blacklist endpoints; explicit server failures and rate limits retain their waiting periods. Existing cancellation cleanup remains.

### Bounded comparison on October 5, 2026

The same public Times Square named-road query was run under both allowance policies, with 225- and 1,200-meter radii. The small-area comparison ran divided first; the larger-area comparison ran restored first. Requests were sequential, so changing service load prevents a causal performance conclusion from this small sample.

| Radius | Divided allowance | Restored allowance |
|---|---|---|
| 225 meters | Success in 1.53 seconds; 156 elements | Success in 2.08 seconds; 156 elements |
| 1,200 meters | All three endpoints timed out; 19.26 seconds total | Success in 2.70 seconds; 3,547 elements |

These successful downloads replace the earlier conclusion that no real-service success had been observed. They do not establish consistent service availability. Controlled tests now explicitly include eight seconds acquiring location followed by a valid ten-second map response, plus an immediate explicit retry after a local timeout.

### Recovery validation

All 149 phone tests passed. The new slow-response test exercised six combinations: Nearest and Upcoming through the phone service, spoken Siri request path, and structured Get request path. Each included eight seconds of acquisition delay and a valid ten-second map response. Watch production-code checks passed the same delayed-response scenario, timeout retry, fallback allowance, and rate-limit handling. The generic iPhone build, including the Watch app, passed.

The downloaded responses were also decoded and processed with the production Watch intersection builder on the development computer: 156 elements yielded 10 intersections in approximately 0.00045 seconds; 3,547 elements yielded 320 intersections in approximately 0.057 seconds. These are desktop processing measurements, not physical Watch timings.

## Earlier corrections

- Phone and Watch compile the same whole-request deadline implementation. Service-level wrappers cover ranked and structured requests as well as basic spoken requests.
- All phone Siri intersection requests use isolated location services and common retry handling, preserving structured result fields.
- Neighborhood information is optional, with at most two seconds and a margin before the overall deadline. Additional spoken intersections also leave a margin to deliver an already-found result.
- Watch fallback requests share the remaining deadline. Offline errors do not mark healthy services unavailable; rate limits stop fallback rotation; services in cooldown are not immediately retried.
- Watch reuses identical successful map queries within an individual request. This is temporary request state, not saved-area support.
- Incomplete Overpass responses containing a remark cannot become cached successful map responses. Bounded fallback handling applies to malformed/incomplete data.
- Live fetches have an explicit deadline, and failed fetches use a one-minute retry interval rather than the normal three-minute walking refresh interval. No new polling timer was added; recovery still depends on location updates.
- Debug builds log request stages, elapsed times, completion state, endpoint host and element count. They do not log device coordinates, street names, response bodies, or spoken answers.

## Live service checks: October 5, 2026

Six sequential checks used the fixed public Times Square coordinate (40.7580, -73.9855), named-road queries matching the app's basic road types, and radii of 225 and 1,200 meters. Each request used a 12-second network timeout; connection setup can add to the measured elapsed time. These checks did not use device location.

| Endpoint | 225-meter query | 1,200-meter query |
|---|---|---|
| overpass-api.de | HTTP 504 after 8.25 seconds | HTTP 504 after 9.15 seconds |
| overpass.private.coffee | Read timeout after 14.48 seconds | Read timeout after 12.34 seconds |
| maps.mail.ru | Read timeout after 12.57 seconds | Read timeout after 12.93 seconds |

One additional tiny control query, requesting node 1 from the primary endpoint, returned HTTP 504. Its Overpass response explicitly identified a dispatcher timeout and said the server was probably too busy. This supports service overload as a contributor on this connection; it does not establish the cause of every tester failure or prove a worldwide outage.

No successful live map response was obtained in that earlier bounded run; the later comparison above did obtain successful responses. Increasing download sizes or shortening error messages cannot establish reliable map availability. A service with suitable capacity and an operational owner is the next infrastructure decision if public-service failures persist. No endpoint or provider was replaced as part of this change.

## Validation boundaries

Automated tests inject network responses and exercise retries, cancellation, optional-detail deadlines, incomplete payloads, and rate limits. Watch map checks compile production service code with a fail-fast location stub; separate acquisition checks exercise production sensor handling with doubles. They do not invoke Siri or test physical GPS, VoiceOver, cellular/Bluetooth transport, or battery use.

Use MapLoadingReliabilityChecks.md for device testing with Apple Intelligence enabled. Do not treat this change as confirmation of release-level reliability while successful real-service and device checks remain outstanding.
