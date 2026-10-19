"use strict";
// Canonical release statement for Session Hub Scanner Bridge OTA.
// The Windows updater (update-session-hub-scanner.ps1, Get-ReleaseStatement)
// rebuilds exactly these bytes from the manifest entry and verifies the
// RSA-SHA256 (PKCS#1 v1.5) signature with a public key pinned in the script.
// Keep FIELD_ORDER and HEADER in sync with the PowerShell implementation.
const crypto = require("crypto");
const fs = require("fs");

const HEADER = "session-hub-scanner-bridge-release/v1";
const FIELD_ORDER = [
  "channel",
  "version",
  "sha256",
  "size_bytes",
  "min_installed_version",
];
const SIGNATURE_ALG = "RSA-SHA256-PKCS1";
const VERSION_RE = /^\d{1,5}\.\d{1,5}\.\d{1,5}$/;
const CHANNEL_RE = /^[a-z0-9][a-z0-9._-]*$/;
const SHA_RE = /^[0-9a-f]{64}$/;
const MAX_PACKAGE_BYTES = 512 * 1024 * 1024;

function compareVersions(a, b) {
  const pa = String(a).split(".").map(Number);
  const pb = String(b).split(".").map(Number);
  for (let i = 0; i < 3; i += 1) {
    if (pa[i] !== pb[i]) return pa[i] < pb[i] ? -1 : 1;
  }
  return 0;
}

function validateEntryFields(entry) {
  const errors = [];
  if (!entry || typeof entry !== "object") return ["ENTRY_NOT_OBJECT"];
  if (!CHANNEL_RE.test(String(entry.channel || ""))) errors.push("CHANNEL_INVALID");
  if (!VERSION_RE.test(String(entry.version || ""))) errors.push("VERSION_INVALID");
  if (!SHA_RE.test(String(entry.sha256 || ""))) errors.push("SHA256_INVALID");
  const size = Number(entry.size_bytes);
  if (!Number.isSafeInteger(size) || size <= 0 || size > MAX_PACKAGE_BYTES)
    errors.push("SIZE_INVALID");
  if (!VERSION_RE.test(String(entry.min_installed_version || "")))
    errors.push("MIN_INSTALLED_VERSION_INVALID");
  else if (
    VERSION_RE.test(String(entry.version || "")) &&
    compareVersions(entry.min_installed_version, entry.version) > 0
  )
    errors.push("MIN_INSTALLED_VERSION_ABOVE_VERSION");
  return errors;
}

function buildStatement(entry) {
  const errors = validateEntryFields(entry);
  if (errors.length) throw new Error("STATEMENT_FIELDS_INVALID:" + errors.join(","));
  const lines = [HEADER].concat(
    FIELD_ORDER.map((field) => field + "=" + String(entry[field])),
  );
  return lines.join("\n") + "\n";
}

function signStatement(statement, privateKeyPem) {
  return crypto
    .sign("sha256", Buffer.from(statement, "utf8"), {
      key: privateKeyPem,
      padding: crypto.constants.RSA_PKCS1_PADDING,
    })
    .toString("base64");
}

function verifyStatement(statement, signatureB64, publicKeyPem) {
  try {
    return crypto.verify(
      "sha256",
      Buffer.from(statement, "utf8"),
      { key: publicKeyPem, padding: crypto.constants.RSA_PKCS1_PADDING },
      Buffer.from(String(signatureB64 || ""), "base64"),
    );
  } catch (_) {
    return false;
  }
}

function b64urlToB64(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  return padded + "=".repeat((4 - (padded.length % 4)) % 4);
}

// Public key in the shape pinned inside the PowerShell updater
// ($PinnedReleaseKeys: key_id, modulus_b64, exponent_b64 for RSACng).
function publicKeyToPin(keyPem, keyId) {
  const publicKey = crypto.createPublicKey(keyPem);
  if (publicKey.asymmetricKeyType !== "rsa") throw new Error("KEY_NOT_RSA");
  const jwk = publicKey.export({ format: "jwk" });
  const modulusBytes = Buffer.from(b64urlToB64(jwk.n), "base64").length;
  if (modulusBytes < 384 || publicKey.asymmetricKeyDetails.modulusLength < 3072) throw new Error("KEY_TOO_SMALL_MIN_3072_BITS");
  return {
    key_id: String(keyId),
    modulus_b64: b64urlToB64(jwk.n),
    exponent_b64: b64urlToB64(jwk.e),
  };
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function buildSignedEntry({
  zipPath,
  channel,
  version,
  minInstalledVersion,
  privateKeyPem,
  keyId,
  packageUrl,
  notes,
}) {
  if (fs.statSync(zipPath).size > MAX_PACKAGE_BYTES) throw new Error("SIZE_INVALID");
  publicKeyToPin(privateKeyPem, keyId);
  const entry = {
    channel,
    version,
    sha256: sha256File(zipPath),
    size_bytes: fs.statSync(zipPath).size,
    min_installed_version: minInstalledVersion,
  };
  const statement = buildStatement(entry);
  const signed = {
    version: entry.version,
    package_url: packageUrl || null,
    sha256: entry.sha256,
    size_bytes: entry.size_bytes,
    min_installed_version: entry.min_installed_version,
    notes: notes || "",
    signature: {
      alg: SIGNATURE_ALG,
      key_id: String(keyId),
      value: signStatement(statement, privateKeyPem),
    },
  };
  return { channel, entry: signed, statement };
}

module.exports = {
  HEADER,
  FIELD_ORDER,
  SIGNATURE_ALG,
  VERSION_RE,
  compareVersions,
  validateEntryFields,
  buildStatement,
  signStatement,
  verifyStatement,
  publicKeyToPin,
  sha256File,
  buildSignedEntry,
};
