import assert from "node:assert/strict";
import { test } from "node:test";
import { formatMoney, minorToInput, parseAmount } from "../public/money.js";

test("parses amounts the way people type them", () => {
  const cases = [
    ["4500", 450000],
    ["4 500", 450000],
    ["4.500", 450000],
    ["4,500", 450000],
    ["4.500,50", 450050],
    ["4,500.50", 450050],
    ["12,5", 1250],
    ["12.50", 1250],
    ["₡4 500,00", 450000],
    ["$12.50", 1250],
    ["1.234.567,89", 123456789],
    ["0,99", 99],
  ];
  for (const [text, minor] of cases) assert.equal(parseAmount(text, "CRC"), minor, text);
  for (const bad of ["", "abc", "-5", ",", null]) assert.equal(parseAmount(bad, "CRC"), null, String(bad));
  assert.equal(parseAmount("1500", "JPY"), 1500);
});

test("formats by region", () => {
  assert.match(formatMoney(450050, "CRC", "es-CR"), /₡\s?4\s?500,50/);
  assert.match(formatMoney(1250, "USD", "en-US"), /\$12\.50/);
  assert.equal(minorToInput(450050, "CRC", "es-CR"), "4500,50");
});
