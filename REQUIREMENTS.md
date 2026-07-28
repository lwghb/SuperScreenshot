# SuperScreenshot Requirements

## Long capture

- Automatic long capture calculates the scroll step from the selected region.
- Each automatic step keeps approximately 20 output pixels of overlap at the bottom of the selected region, then captures and stitches one frame.
- The implementation must validate the detected displacement against the requested step so repeated content cannot cause skipped sections.
- The long-capture preview must stay on the display containing the selected region, including when the selection overlay is non-activating.
- Automatic scrolling must wait until the current frame has been stitched and its preview committed before starting the next scroll step.

## Capture consistency

- The selection background and the final capture should represent the same visible screen state; transient window visibility differences must not cause surprising content to appear only in the final image.
- The selection overlay must not activate SuperScreenshot or cause another application's focus-sensitive plug-in window to hide.
- Opening the selection overlay must be immediate, without a screen zoom or scale animation on any display.
