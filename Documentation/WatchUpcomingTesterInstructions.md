# Watch Upcoming test instructions

This test checks whether Upcoming follows the Watch's direction, and how long the answer takes.

## Before you start

1. Install the test build containing these changes on both the iPhone and Apple Watch. Ask Marco to confirm that you have the correct build.
2. Open Intersector once on each device. Allow location access if asked.
3. Leave Apple Intelligence on. Keep your usual phone and Watch connection.
4. Choose a familiar street where you know the next intersection. Stop in a safe place before testing.

## Test 1: Ask Siri on the Watch

1. Activate Siri directly on the Watch, using the Digital Crown or your usual Watch control. This helps avoid the phone hearing the request instead.
2. Say: “Upcoming intersection in Intersector.”
3. Note the intersection name and roughly how many seconds pass between finishing your question and the answer beginning. An estimate is fine.
4. Repeat once from the same place. Note whether the second answer is faster.

## Test 2: Change only the phone's direction

1. Stay in the same place and hold your Watch steadily in the same direction.
2. Turn only the phone so it points in a different direction. A helper can do this if easier. Avoid holding the phone close to the Watch.
3. Activate Siri directly on the Watch and say: “Upcoming intersection in Intersector.”
4. Note the intersection name, and approximate wait.

Turning only the phone should not change the Watch's compass heading. A changed intersection alone does not prove the phone supplied the heading; please report exactly what changed.

## Test 3: Change the Watch's direction

1. Keep the phone in the same position.
2. Turn yourself and your Watch to face the opposite direction along the street. Hold the Watch steadily as you normally would when checking direction.
3. Ask Siri on the Watch: “Upcoming intersection in Intersector.”
4. Note the intersection name, and approximate wait. Tell us whether the named intersection makes sense for the new direction.

## Test 4: Compare with the Watch app

1. Open Intersector on the Watch.
2. Face the same direction used in Test 3 and activate Upcoming in the app.
3. Note the intersection name and approximate wait. Tell us whether it agrees with Siri.

## Test 5: Check another Siri phrase

Activate Siri directly on the Watch and say: “What's the next intersection with Intersector?” Note whether it works and what answer you hear.

## Check the spoken and displayed response

For each Siri test, please tell us:

- Was the answer spoken once, repeated, or not spoken?
- Could VoiceOver read the final response text?
- Was there an empty response bubble? If so, did the answer eventually replace it, or did it stay empty?
- Did Siri give an error or stop without answering? If so, what did it say and roughly how long did you wait?

Do not disable VoiceOver or Apple Intelligence to perform these checks. If a displayed detail is not accessible, report that; no screenshot is needed.

## What to send back

Please include your Watch model, watchOS version, iPhone model, iOS version, and test build number if available. Also mention whether the phone was nearby and connected normally.

You can copy this format for each test:

Test number:
Intersection announced:
Approximate wait:
Did the intersection make sense for the Watch's direction?
Was the answer spoken once?
Could VoiceOver read the response?
Did an empty bubble remain?
Other notes:

## Check Manhattan Snob Mode

1. On the iPhone, open Intersector Settings and turn Manhattan Snob Mode on. For intersection announcements, choose Cardinal direction style and make sure Direction is included in announcements.
2. Open Intersector on the Watch while it is connected to the phone so it can receive the setting.
3. Use My Direction in the Watch app. Repeat while facing a few different directions. Expected wording is:

| Compass direction | Manhattan wording |
|---|---|
| North or northeast | Uptown |
| East or southeast | East Side |
| South or southwest | Downtown |
| West or northwest | West Side |

4. Try Upcoming in the Watch app and then through Siri on the Watch. When a direction is included, it should use these same four terms. It should no longer say combinations such as “uptown toward the West Side.”
5. Turn Manhattan Snob Mode off on the phone, then open Intersector on the Watch again. My Direction should return ordinary compass wording such as “northwest.”

My Direction describes which way the Watch is pointing. The direction in an Upcoming report describes where the intersection is, so those two answers do not have to be identical. Compare phone and Watch wording only when they report the same compass direction; the devices can be pointing in different directions.

If the Watch keeps using the previous mode after you change the setting, report that separately. Please include the exact words it spoke and whether you used the Watch app or Siri. Keep Apple Intelligence enabled throughout.

## Check asking again on the iPhone

Leave Apple Intelligence on for these checks.

1. Ask Siri on the iPhone for the nearest intersection, then for the upcoming intersection. The answer should begin with the intersection information, without saying “iPhone response.”
2. If a request fails, note the exact words Siri says and roughly how long you waited.
3. Follow the advice in the response, then ask again. If it mentions your connection, check that you have internet access. If it asks you to wait a minute, wait before asking again. If it cannot find an intersection ahead, face along the street and hold the phone steady.
4. Report whether the next request gives an intersection or repeats the error, and how long it takes. You should not need to close and reopen Intersector to ask again.

On the Watch, intersection answers should no longer begin with “Watch response.” The retry changes in this build apply to the iPhone's built-in Nearest and Upcoming Siri requests. Please report any Watch failures separately.
