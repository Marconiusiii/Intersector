# Map-loading reliability review

## Documented request policy: October 6, 2026

The shared phone/Watch server allowance now accounts for up to 15 seconds of Overpass queueing, a declared 10-second execution limit, and a five-second transport margin. Each attempt gets at most 30 seconds within the existing 60-second overall deadline. Near the overall deadline, an attempt may receive less time. This is a client correction, not proof of Siri's execution lifetime or public-server reliability.

Road and neighborhood requests share endpoint health. HTTP 429 and 406 stop rotation within that request, and Retry-After seconds or HTTP dates extend the minimum 60-second cooldown. Offline failures and local timeouts do not blacklist a service. Optional neighborhood work retains its short deadline.

Queries declare a 32 MiB memory limit. The six cases below use templates extracted from the production query builders and a fixed public Times Square coordinate. The resource cap was accepted on these samples; the public API does not report exact peak server memory. This is not a worldwide coverage benchmark.

| Query | Response bytes | Elements | Elapsed seconds | Result |
|---|---|---|---|---|
| Roads, 225 meters | 36,016 | 156 | 5.206 | Complete |
| Crossings, 225 meters | 58,207 | 271 | 9.910 | Complete |
| Roads and walking paths, 1,200 meters | 948,446 | 3,712 | 2.228 | Complete |
| Crossings, 1,200 meters | 941,288 | 3,662 | 2.816 | Complete |
| Focused road with crossings, 1,200 meters | 315,691 | 1,356 | 2.268 | Complete |
| Neighborhoods, 1,000 meters, after backoff | 5,256 | 12 | 1.463 | Complete |

The first neighborhood probe received HTTP 429 from the primary. The probe script then tried a fallback, which timed out after 30.342 seconds. That probe behavior did not follow the intended backoff policy and was corrected for the follow-up: one primary-only request after backoff succeeded. Production clients now stop rotation on rate-limit responses.

Successful basic road responses persist in a protected, bounded cache: four areas, 15-minute reuse, 8 MiB per response, 32 MiB total archive. The existing coverage and option checks apply. Explicit fresh requests bypass stored responses; incomplete/cancelled results are not saved. No background polling or saved-area controls were added.

Lookup diagnostics now use system notices in both Debug and Release builds. Phone and Watch Nearest/Upcoming intents log entry and prepared dialog return with request correlation. Startup has a separate request identifier. Logs exclude coordinates, street names, response bodies, and spoken results.

References: [Overpass queueing and resource rules](https://dev.overpass-api.de/overpass-doc/en/preface/commons.html) and [Overpass request format and usage guidance](https://wiki.openstreetmap.org/wiki/Overpass_API).

Validation: all 173 phone unit tests passed, with 187 executions including parameterized cases and no failures or skipped tests. Production Watch checks passed offline retry, request reuse, incomplete-response fallback, queued valid responses, timeout retry, cooldown, disk restoration, resource declarations, and Retry-After handling. The final Release iPhone build, including the Watch app, passed with signing disabled. The diff check passed.

Regression coverage also verifies that disk restoration preserves the original download age and area center when populating the phone memory cache, rather than extending expiration or shifting coverage. Physical cold Siri, locked-phone, GPS, VoiceOver, Watch transport, and battery behavior remain unverified.


## Startup investigation: October 5, 2026

Startup now identifies location acquisition separately and gives related diagnostic events a request identifier. Debug output includes cache decisions, host, per-server allowance, HTTP status, response byte count, malformed or incomplete payload classification, deadlines, and error domain/code. It excludes coordinates, street names, response bodies, and localized error details. Request allowances and endpoint selection are unchanged.

A bounded check extracted the production 225-meter startup query and its form encoding directly from `MapDataClient.swift`. It used the fixed public Times Square coordinate, once without crossings and once with crossings; walking paths and highways were off. Requests followed the configured endpoint order with the existing 12-second allowance.

| Query | Primary endpoint | First fallback | Second fallback | Total |
|---|---|---|---|---|
| Streets | HTTP 504 in 7.63 seconds | No response bytes within 12 seconds | No response bytes within 12 seconds | 31.70 seconds |
| Streets and crossings | No response bytes within 12 seconds | No response bytes within 12 seconds | No response bytes within 12 seconds | 36.09 seconds |

No usable map response was received in this check. This reproduces a download failure outside the app from the development connection, but does not establish the cause on the user's phone or prove a global outage. Map reliability remains unresolved. The next device evidence is the Lookup output from a failed startup and its retry, using the added stage diagnostics.

The home screen now uses a native navigation title and toolbar. Physical VoiceOver startup focus still requires testing. Settings helper paragraphs have moved to the relevant Help topics.

Validation: the generic iPhone build, including the Watch app, passed. All 159 tests in eight suites passed in 110.512 seconds, including slow responses, retries, Siri requests, and the new diagnostic privacy and request-correlation checks. These automated results do not establish reliable live downloads or correct physical-device VoiceOver focus.


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
