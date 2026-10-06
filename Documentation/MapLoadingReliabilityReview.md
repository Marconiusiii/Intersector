# Map-loading reliability review

## Scope

Phone app startup and intersection requests, phone Live, built-in Siri intersection actions, structured Get actions, and Watch app/Siri requests. Saved-area downloads remain deferred.

## Corrections

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

No successful live map response was obtained in this bounded run. Increasing download sizes or shortening error messages cannot establish reliable map availability. A service with suitable capacity and an operational owner is the next infrastructure decision if public-service failures persist. No endpoint or provider was replaced as part of this change.

## Validation boundaries

Automated tests inject network responses and exercise retries, cancellation, optional-detail deadlines, incomplete payloads, and rate limits. Watch map checks compile production service code with a fail-fast location stub; separate acquisition checks exercise production sensor handling with doubles. They do not invoke Siri or test physical GPS, VoiceOver, cellular/Bluetooth transport, or battery use.

Use MapLoadingReliabilityChecks.md for device testing with Apple Intelligence enabled. Do not treat this change as confirmation of release-level reliability while successful real-service and device checks remain outstanding.
