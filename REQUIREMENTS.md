# SuperScreenshot Requirements

## Long capture

- Automatic long capture calculates the scroll step from the selected region.
- Each automatic step keeps approximately 20 output pixels of overlap at the bottom of the selected region, then captures and stitches one frame.
- The implementation must validate the detected displacement against the requested step so repeated content cannot cause skipped sections.

## Capture consistency

- The selection background and the final capture should represent the same visible screen state; transient window visibility differences must not cause surprising content to appear only in the final image.
- The selection overlay must not activate SuperScreenshot or cause another application's focus-sensitive plug-in window to hide.
