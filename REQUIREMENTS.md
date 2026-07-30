# SuperScreenshot Requirements

## Long capture

- Automatic long capture calculates the scroll step from the selected region.
- Each automatic step retains at least 64 output pixels of overlap for reliable matching, then captures and stitches one frame. It should still use a near-full-region step rather than small incremental scrolling.
- The implementation must validate the detected displacement against the requested step so repeated content cannot cause skipped sections.
- The long-capture preview must stay on the display containing the selected region, including when the selection overlay is non-activating.
- Automatic scrolling must wait until the current frame has been stitched and its preview committed before starting the next scroll step.

## Capture consistency

- The selection background and the final capture should represent the same visible screen state; transient window visibility differences must not cause surprising content to appear only in the final image.
- The selection overlay must not activate SuperScreenshot or cause another application's focus-sensitive plug-in window to hide.
- Opening the selection overlay must be immediate, without a screen zoom or scale animation on any display.

## Annotation toolbar

- The screenshot annotation toolbar must be draggable by its empty background so it can be moved away from a tall or near-full-screen selected region.

## Selection color readout

- Rendering the cursor color readout must tolerate unavailable system fonts and must never crash the capture overlay.
