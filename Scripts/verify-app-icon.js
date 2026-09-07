ObjC.import("AppKit");

function run(args) {
    if (args.length !== 2) throw new Error("Usage: verify-app-icon.js DECODED_PNG MASTER_PNG");
    const actual = $.NSBitmapImageRep.imageRepWithContentsOfFile(args[0]);
    const master = $.NSBitmapImageRep.imageRepWithContentsOfFile(args[1]);
    if (!actual || !master) throw new Error("Could not decode icon images");
    if (Number(actual.pixelsWide) !== 1024 || Number(actual.pixelsHigh) !== 1024)
        throw new Error("Packaged icon must contain its 1024px representation");
    // The stale packaged icon retained an opaque white square around the
    // rounded artwork. Verify padding and silhouette against the master.
    const points = [0, 32, 128, 256, 512, 768, 895, 992, 1023];
    for (const x of points) for (const y of points) {
        const a = Number(actual.colorAtXY(x, y).alphaComponent);
        const b = Number(master.colorAtXY(x, y).alphaComponent);
        if (Math.abs(a - b) > 1 / 255)
            throw new Error("Packaged icon alpha differs from master at " + x + "," + y + ": " + a + " vs " + b);
    }
    return "Packaged icon transparency matches the canonical master";
}
