import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const sdkRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const apiEntryPath = path.join(sdkRoot, "packages", "api", "index.js");

function loadAPI() {
  const source = fs.readFileSync(apiEntryPath, "utf8");
  const module = { exports: {} };
  const fakeReact = {
    createElement(type, props, ...children) {
      const { key, ...restProps } = props ?? {};
      return {
        key: key ?? null,
        type,
        props: {
          ...restProps,
          children: children.length <= 1 ? children[0] : children,
        },
      };
    },
    isValidElement(value) {
      return Boolean(value && typeof value === "object" && "type" in value && "props" in value);
    },
  };

  const sandbox = {
    module,
    exports: module.exports,
    require(specifier) {
      switch (specifier) {
        case "react":
          return fakeReact;
        case "./hooks/useLocalStorage":
          return { useLocalStorage() {} };
        case "./hooks/usePromise":
          return { usePromise() {} };
        case "./hooks/useFetch":
          return { useFetch() {} };
        case "./functions/openURL":
          return { openURL() {} };
        case "./runtime":
          return { LocalStorage: {} };
        default:
          throw new Error(`Unexpected dependency: ${specifier}`);
      }
    },
  };

  vm.runInNewContext(source, sandbox, { filename: apiEntryPath });
  return module.exports;
}

test("@notchapp/api exports the extended non-image component surface", () => {
  const api = loadAPI();

  for (const name of [
    "Stack",
    "Inline",
    "Spacer",
    "Text",
    "Icon",
    "Image",
    "Button",
    "Row",
    "IconButton",
    "Checkbox",
    "Input",
    "ScrollView",
    "Divider",
    "Circle",
    "RoundedRect",
  ]) {
    assert.equal(typeof api[name], "function", `${name} should be exported`);
  }
});

test("component wrappers emit host elements with the expected props", () => {
  const api = loadAPI();

  const row = api.Row({
    onPress: () => {},
    children: [
      api.Icon({ symbol: "sparkles" }),
      api.Text({ children: "Capture" }),
    ],
  });
  const input = api.Input({
    value: "Draft",
    placeholder: "Type",
    onChange: () => {},
    onSubmit: () => {},
    trailingAccessory: api.Icon({ symbol: "mic" }),
  });
  const roundedRect = api.RoundedRect({
    fill: "#111111",
    overlay: api.IconButton({ key: "overlay-plus", symbol: "plus", onPress: () => {} }),
  });
  const image = api.Image({
    src: "assets/cover.png",
    opacity: 0.8,
    contentMode: "fit",
  });
  const inputChildren = Array.isArray(input.props.children) ? input.props.children : [input.props.children];
  const roundedRectChildren = Array.isArray(roundedRect.props.children)
    ? roundedRect.props.children
    : [roundedRect.props.children];

  assert.equal(row.type, "Row");
  assert.equal(input.type, "Input");
  assert.equal(roundedRect.type, "RoundedRect");
  assert.equal(image.type, "Image");

  assert.equal(input.props.value, "Draft");
  assert.equal(input.props.placeholder, "Type");
  assert.equal(image.props.src, "assets/cover.png");
  assert.equal(image.props.opacity, 0.8);
  assert.equal(image.props.contentMode, "fit");
  assert.equal(Array.isArray(row.props.children), true);
  assert.equal(inputChildren[0].type, "__notch_trailingAccessory");
  assert.equal(inputChildren[0].props.children.type, "Icon");
  assert.equal(roundedRectChildren[0].type, "__notch_overlay");
  assert.equal(roundedRectChildren[0].key, "overlay-plus");
  assert.equal(roundedRectChildren[0].props.children.type, "IconButton");
});
