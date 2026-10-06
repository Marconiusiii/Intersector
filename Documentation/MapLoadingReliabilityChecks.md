# Map-loading test instructions

Install the same test build on the iPhone and Watch. Leave Apple Intelligence and VoiceOver enabled. Use a familiar intersection and stop in a safe place before testing.

## iPhone

1. Open Intersector and ask for Nearest, then Upcoming. Note the answer and roughly how many seconds it takes.
2. Ask again from the same place. Report whether the next answer is faster, slower, or fails.
3. Start Live while walking along a familiar street. Report whether it announces successive intersections. Stop Live when finished.
4. Ask Siri for Nearest and Upcoming. Also try the second and third intersection requests if you normally use them.
5. Run one of your own shortcuts that uses Intersector's Get actions. Confirm its text output still works.

## Apple Watch

1. Open Intersector on the Watch and request Nearest, then Upcoming.
2. Activate Siri directly on the Watch and repeat those requests.
3. Keep the phone still, turn yourself and your Watch to face the other direction along the street, and ask for Upcoming again. Report whether the answer matches that direction.
4. Run a custom shortcut using a Watch Get action if you have one.

## When a request fails

1. Note the exact words and roughly how long you waited. Say whether the app kept indicating that it was loading.
2. Follow the instruction in the response, then make the same request again. If it asks you to wait a minute, wait before retrying.
3. Report whether that next request succeeds. Do not close and reopen the app before this retry.
4. For Siri, say whether it spoke an answer, remained silent, or left an empty response bubble. No screenshot is needed.

## What to send back

- Device and test build.
- Whether you used the app, Siri, or a custom shortcut.
- The request, answer or exact error, and approximate wait.
- Whether the next request worked.
- Whether you were using Wi-Fi or cellular, and whether the Watch was connected to the phone.
- A nearby public intersection, if you are comfortable sharing it. A home address is not needed.

A passing build or automated test does not replace these device checks.
