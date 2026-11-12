/* oxlint-disable t3code/no-global-process-runtime -- Packaging runs on the build host and shells out to codesign. */
const { spawnSync } = require("node:child_process");
const path = require("node:path");

// An unsigned macOS build still needs a valid signature: without one, Apple Silicon reports
// the downloaded app as "damaged". Ad-hoc signing the whole bundle makes it the ordinary
// "unidentified developer" app (right-click, Open). Runs after electron-builder's own signing
// step, which is skipped for unsigned builds, and does nothing for a build with a real identity.
module.exports = async ({ appOutDir, electronPlatformName, packager }) => {
  if (electronPlatformName !== "darwin" || process.platform !== "darwin") return;
  if (process.env.T3CODE_DESKTOP_SIGNED === "true") return;
  const app = path.join(appOutDir, `${packager.appInfo.productFilename}.app`);
  const result = spawnSync(
    "codesign",
    ["--force", "--deep", "--sign", "-", "--timestamp=none", app],
    {
      stdio: "inherit",
    },
  );
  if (result.status !== 0) {
    throw new Error(`Ad-hoc signing ${app} failed (exit ${result.status}).`);
  }
  const verify = spawnSync("codesign", ["--verify", "--deep", "--strict", app], {
    stdio: "inherit",
  });
  if (verify.status !== 0) {
    throw new Error(`${app} does not verify after ad-hoc signing.`);
  }
  console.log(`[adhoc-sign] Signed ${app}`);
};
