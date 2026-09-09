import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("the reference-market script binds both token identity fields to the release environment", async () => {
  const source = await readFile(new URL("./EventsBaseSepoliaReferenceMarket.s.sol", import.meta.url), "utf8");
  assert.match(source, /token = vm\.envBytes32\("SVM_DEFAULT_SRC20_ID"\)/);
  assert.match(source, /tokenCodeHash = vm\.envBytes32\("SVM_DEFAULT_SRC20_CODE_HASH"\)/);
  assert.match(source, /kernel\.programCodeHash\(worldId, token\) == tokenCodeHash/);
  assert.match(source, /new SwapVMSRC20Market\(router, worldId, token, tokenCodeHash, escrow, ESCROW_CODE_HASH\)/);
  assert.doesNotMatch(source, /0xaf15e40fe9fc1181a7143abb413562d69e1ab49a655209ac966204646c85c14b/);
});
