#!/usr/bin/env node
"use strict";
// Offline helper for the release operator (Root). It never uploads, publishes
// or edits a manifest: it prints a signed manifest entry or a public-key pin.
//
//   node tools/sign-release.js sign --zip <zip> --channel stable \
//     --version 1.1.0 --min-installed-version 1.1.0 \
//     --key <private.pem> --key-id <id> [--package-url <url>] [--notes <text>]
//   node tools/sign-release.js pin --key <public-or-private.pem> --key-id <id>
//   node tools/sign-release.js verify --entry <entry.json> --channel stable \
//     --zip <zip> --public-key <public.pem>
const fs = require("fs");
const lib = require("./release-statement");

function parse(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) {
      out._.push(token);
      continue;
    }
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) throw new Error("ARGUMENT_VALUE_REQUIRED:" + token);
    out[token.slice(2)] = next;
    i += 1;
  }
  return out;
}

function need(args, key) {
  if (!args[key]) throw new Error("ARGUMENT_REQUIRED:--" + key);
  return args[key];
}

function main() {
  const args = parse(process.argv.slice(2));
  const command = args._[0];
  if (command === "sign") {
    const result = lib.buildSignedEntry({
      zipPath: need(args, "zip"),
      channel: need(args, "channel"),
      version: need(args, "version"),
      minInstalledVersion: need(args, "min-installed-version"),
      privateKeyPem: fs.readFileSync(need(args, "key"), "utf8"),
      keyId: need(args, "key-id"),
      packageUrl: args["package-url"],
      notes: args.notes,
    });
    process.stdout.write(JSON.stringify({ channel: result.channel, entry: result.entry }, null, 2) + "\n");
    return;
  }
  if (command === "pin") {
    const pin = lib.publicKeyToPin(fs.readFileSync(need(args, "key"), "utf8"), need(args, "key-id"));
    process.stdout.write(JSON.stringify(pin, null, 2) + "\n");
    return;
  }
  if (command === "verify") {
    const raw = JSON.parse(fs.readFileSync(need(args, "entry"), "utf8"));
    const entry = raw.entry || raw;
    const channel = need(args, "channel");
    const zip = need(args, "zip");
    const actualSha = lib.sha256File(zip);
    const actualSize = fs.statSync(zip).size;
    const statement = lib.buildStatement({ ...entry, channel });
    const ok =
      actualSha === entry.sha256 &&
      actualSize === Number(entry.size_bytes) &&
      entry.signature &&
      entry.signature.alg === lib.SIGNATURE_ALG &&
      lib.verifyStatement(statement, entry.signature.value, fs.readFileSync(need(args, "public-key"), "utf8"));
    process.stdout.write(JSON.stringify({ ok: Boolean(ok), sha256: actualSha, size_bytes: actualSize }) + "\n");
    process.exit(ok ? 0 : 2);
  }
  throw new Error("COMMAND_REQUIRED:sign|pin|verify");
}

try {
  main();
} catch (error) {
  process.stderr.write("[sign-release] " + error.message + "\n");
  process.exit(1);
}
