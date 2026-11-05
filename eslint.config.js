import js from "@eslint/js";
import globals from "globals";

export default [
  { ignores: ["node_modules/", "ios/", ".wrangler/", "public/vendor/"] },
  js.configs.recommended,
  {
    files: ["src/**/*.js", "tests/**/*.js", "scripts/**/*.js", "eslint.config.js"],
    languageOptions: { ecmaVersion: "latest", sourceType: "module", globals: { ...globals.node } },
  },
  {
    files: ["public/**/*.js"],
    languageOptions: { ecmaVersion: "latest", sourceType: "module", globals: { ...globals.browser } },
  },
  {
    rules: {
      "no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
      eqeqeq: "error",
      "no-var": "error",
      "prefer-const": "error",
    },
  },
];
