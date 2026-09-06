# Direct file sharing

Add Send file to the device context menu. Use a separate TLS/admitted fileTransfer channel to a current room peer, with bounded chunk flow, receiver acknowledgement, a digest, cancellation, timeout, and temporary-file cleanup. Never put file bytes in replicated room history or audio queues.

Ordinary files require Accept/Decline before transfer and a save destination after completion. Raster images, movies, and audio may auto-accept into temporary storage; verify the actual content before presenting it. Unsupported or invalid content never launches an external app.

Present media in a floating, borderless, resizable window. Reveal accessible save, annotate, send-back, display selection, pin, and close controls on hover. Annotation uses an image or paused video frame and sends a flattened PNG back through the same transfer flow. Show progress and errors, cap concurrent transfers and media windows, and retire transfers on room leave.

Validate wire bounds, filename handling, sequencing, byte count, checksum, rejected offers, and lifecycle behavior. Run Mac and iOS CI and package the next release after required gates pass.
