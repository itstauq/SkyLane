import assert from "node:assert/strict";
import { test } from "node:test";
import { createRequire } from "node:module";

import { invoke as invokeCallback } from "../callback-registry.mjs";
import { createRenderer } from "../reconciler.mjs";

const require = createRequire(import.meta.url);
const React = require("react");
const OVERLAY_SLOT_TYPE = "__notch_overlay";
const LEADING_ACCESSORY_SLOT_TYPE = "__notch_leadingAccessory";
const TRAILING_ACCESSORY_SLOT_TYPE = "__notch_trailingAccessory";

function renderTree(element) {
  const renderer = createRenderer();
  let commit = null;
  renderer.onCommit((payload) => {
    commit = payload;
  });
  renderer.render(element);
  assert.ok(commit);
  return commit.data;
}

function overlaySlot(child, alignment = "center", key) {
  return React.createElement(OVERLAY_SLOT_TYPE, key == null ? { alignment } : { alignment, key }, child);
}

function leadingAccessorySlot(child) {
  return React.createElement(LEADING_ACCESSORY_SLOT_TYPE, null, child);
}

function trailingAccessorySlot(child) {
  return React.createElement(TRAILING_ACCESSORY_SLOT_TYPE, null, child);
}

async function flushEffects() {
  await new Promise((resolve) => setImmediate(resolve));
}

test("reconciler serializes the new component wrappers into v2 host nodes", () => {
  const tree = renderTree(
    React.createElement(
      "Stack",
      { spacing: 12, alignment: "center" },
        React.createElement(
          "Inline",
          { spacing: 6, alignment: "top" },
          React.createElement("Icon", { symbol: "star.fill", size: 16 }),
          React.createElement("Image", { src: "assets/cover.png" }),
          React.createElement("Text", { tone: "secondary", lineClamp: 1 }, "Hello"),
          React.createElement("Spacer", { minLength: 4 })
        ),
      React.createElement(
        "ScrollView",
        { spacing: 8, fadeEdges: "both" },
        React.createElement("Divider", { color: "#FF0000AA" }),
        React.createElement("Circle", { size: 12, fill: "#FFFFFF" }),
        React.createElement("RoundedRect", { width: 20, height: 10, cornerRadius: 4, fill: "#111111" })
      ),
      React.createElement("Row", null, React.createElement("Text", null, "Row")),
      React.createElement("IconButton", { symbol: "trash", size: "large" }),
      React.createElement("Checkbox", { checked: true }),
      React.createElement("Input", { value: "Draft", placeholder: "Type here" })
    )
  );

  assert.equal(tree.type, "Stack");
  assert.equal(tree.children[0].type, "Inline");
  assert.equal(tree.children[0].children[0].type, "Icon");
  assert.equal(tree.children[0].children[1].type, "Image");
  assert.equal(tree.children[0].children[1].props.src, "assets/cover.png");
  assert.equal(tree.children[0].children[2].type, "Text");
  assert.equal(tree.children[0].children[3].type, "Spacer");

  assert.equal(tree.children[1].type, "ScrollView");
  assert.equal(tree.children[1].children[0].type, "Divider");
  assert.equal(tree.children[1].children[1].type, "Circle");
  assert.equal(tree.children[1].children[2].type, "RoundedRect");

  assert.equal(tree.children[2].type, "Row");
  assert.equal(tree.children[3].type, "IconButton");
  assert.equal(tree.children[4].type, "Checkbox");
  assert.equal(tree.children[5].type, "Input");
});

test("reconciler normalizes overlay and accessory nodes and keeps callback props", () => {
  let overlayPayload = null;
  let accessoryPayload = null;
  let submitPayload = null;

  const tree = renderTree(
    React.createElement(
      "Stack",
      null,
      React.createElement(
        "RoundedRect",
        { fill: "#101010" },
        overlaySlot(
          React.createElement("IconButton", {
            symbol: "plus",
            onPress: (payload) => {
              overlayPayload = payload;
            },
          }),
          "topTrailing"
        )
      ),
      React.createElement(
        "Input",
        {
          value: "Draft",
          placeholder: "Capture",
          onChange: (payload) => {
            accessoryPayload = payload;
          },
          onSubmit: (payload) => {
            submitPayload = payload;
          },
        },
        leadingAccessorySlot(
          React.createElement("IconButton", {
            symbol: "sparkles",
            onPress: (payload) => {
              accessoryPayload = payload;
            },
          })
        ),
        trailingAccessorySlot(React.createElement("Icon", { symbol: "mic" }))
      )
    )
  );

  const roundedRect = tree.children[0];
  const input = tree.children[1];

  assert.equal(roundedRect.props.overlay[0].alignment, "topTrailing");
  assert.equal(roundedRect.props.overlay[0].node.type, "IconButton");
  assert.match(roundedRect.props.overlay[0].node.props.onPress, /^cb_/);

  assert.equal(input.props.leadingAccessory.type, "IconButton");
  assert.equal(input.props.trailingAccessory.type, "Icon");
  assert.match(input.props.leadingAccessory.props.onPress, /^cb_/);
  assert.match(input.props.onChange, /^cb_/);
  assert.match(input.props.onSubmit, /^cb_/);

  invokeCallback(roundedRect.props.overlay[0].node.props.onPress, { source: "overlay" });
  invokeCallback(input.props.leadingAccessory.props.onPress, { source: "leading" });
  invokeCallback(input.props.onSubmit, { value: "Submitted" });

  assert.deepEqual(overlayPayload, { source: "overlay" });
  assert.deepEqual(accessoryPayload, { source: "leading" });
  assert.deepEqual(submitPayload, { value: "Submitted" });
});

test("reconciler renders nested overlay and accessory components through React", () => {
  function HookAccessory(props) {
    const [symbol] = React.useState(props.symbol);
    return React.createElement("IconButton", { symbol, onPress: props.onPress });
  }

  class ClassAccessory extends React.Component {
    render() {
      return React.createElement("Icon", { symbol: this.props.symbol });
    }
  }

  const tree = renderTree(
    React.createElement(
      "Stack",
      null,
      React.createElement(
        "RoundedRect",
        null,
        overlaySlot(React.createElement(HookAccessory, { symbol: "plus" }))
      ),
      React.createElement(
        "Input",
        { value: "Draft" },
        leadingAccessorySlot(React.createElement(HookAccessory, { symbol: "sparkles" })),
        trailingAccessorySlot(React.createElement(ClassAccessory, { symbol: "mic" }))
      )
    )
  );

  assert.equal(tree.children[0].props.overlay[0].node.type, "IconButton");
  assert.equal(tree.children[0].props.overlay[0].node.props.symbol, "plus");
  assert.equal(tree.children[1].props.leadingAccessory.type, "IconButton");
  assert.equal(tree.children[1].props.leadingAccessory.props.symbol, "sparkles");
  assert.equal(tree.children[1].props.trailingAccessory.type, "Icon");
  assert.equal(tree.children[1].props.trailingAccessory.props.symbol, "mic");
});

test("reconciler serializes frame infinity sentinels and flattens fragment overlays", () => {
  const tree = renderTree(
    React.createElement(
      "RoundedRect",
      { frame: { maxWidth: Infinity, maxHeight: Infinity } },
      overlaySlot(
        React.createElement(
          React.Fragment,
          null,
          React.createElement("IconButton", { symbol: "plus" }),
          React.createElement("Icon", { symbol: "mic" })
        )
      )
    )
  );

  assert.equal(tree.props.frame.maxWidth, "infinity");
  assert.equal(tree.props.frame.maxHeight, "infinity");
  assert.equal(tree.props.overlay.length, 2);
  assert.equal(tree.props.overlay[0].node.type, "IconButton");
  assert.equal(tree.props.overlay[1].node.type, "Icon");
});

test("text nodes preserve overlay slot children while keeping flattened text content", () => {
  const tree = renderTree(
    React.createElement(
      "Text",
      null,
      "Hello",
      overlaySlot(React.createElement("Icon", { symbol: "plus" }), "trailing")
    )
  );

  assert.equal(tree.type, "Text");
  assert.equal(tree.props.text, "Hello");
  assert.equal(tree.children.length, 0);
  assert.equal(tree.props.overlay.length, 1);
  assert.equal(tree.props.overlay[0].alignment, "trailing");
  assert.equal(tree.props.overlay[0].node.type, "Icon");
});

test("reconciler preserves stable node ids across keyed reorders", () => {
  const renderer = createRenderer();
  const commits = [];
  renderer.onCommit((payload) => {
    commits.push(payload);
  });

  renderer.render(
    React.createElement(
      "Stack",
      null,
      React.createElement("Row", { key: "alpha" }, React.createElement("Text", null, "Alpha")),
      React.createElement("Row", { key: "beta" }, React.createElement("Text", null, "Beta"))
    )
  );

  const initialTree = commits.at(-1).data;
  const alphaId = initialTree.children[0].id;
  const betaId = initialTree.children[1].id;

  renderer.render(
    React.createElement(
      "Stack",
      null,
      React.createElement("Row", { key: "beta" }, React.createElement("Text", null, "Beta")),
      React.createElement("Row", { key: "alpha" }, React.createElement("Text", null, "Alpha"))
    )
  );
  renderer.emitFullTree();

  const reorderedTree = commits.at(-1).data;
  assert.equal(reorderedTree.children[0].id, betaId);
  assert.equal(reorderedTree.children[1].id, alphaId);
});

test("keyed overlay items preserve node identity across reorder", () => {
  const renderer = createRenderer();
  const commits = [];
  renderer.onCommit((payload) => {
    commits.push(payload);
  });

  function App(props) {
    return React.createElement(
      "RoundedRect",
      null,
      ...props.items.map((item) =>
        overlaySlot(
          React.createElement("IconButton", { symbol: item.symbol }),
          "center",
          item.key
        )
      )
    );
  }

  renderer.render(
    React.createElement(App, {
      items: [
        { key: "alpha", symbol: "a.circle" },
        { key: "beta", symbol: "b.circle" },
      ],
    })
  );

  const initialTree = commits.at(-1).data;
  const firstOverlayId = initialTree.props.overlay[0].node.id;
  const secondOverlayId = initialTree.props.overlay[1].node.id;

  renderer.render(
    React.createElement(App, {
      items: [
        { key: "beta", symbol: "b.circle" },
        { key: "alpha", symbol: "a.circle" },
      ],
    })
  );
  renderer.emitFullTree();

  const reorderedTree = commits.at(-1).data;
  assert.equal(reorderedTree.props.overlay[0].node.id, secondOverlayId);
  assert.equal(reorderedTree.props.overlay[1].node.id, firstOverlayId);
});

test("overlay state persists across renders without remounting a nested root", async () => {
  const renderer = createRenderer();
  const commits = [];
  renderer.onCommit((payload) => {
    commits.push(payload);
  });

  function StatefulOverlay() {
    const [count, setCount] = React.useState(0);
    return React.createElement("IconButton", {
      symbol: String(count),
      onPress: () => {
        setCount((value) => value + 1);
      },
    });
  }

  function App(props) {
    return React.createElement(
      "RoundedRect",
      { fill: props.fill },
      overlaySlot(React.createElement(StatefulOverlay))
    );
  }

  renderer.render(React.createElement(App, { fill: "#111111" }));
  let tree = commits.at(-1).data;
  const originalOverlayId = tree.props.overlay[0].node.id;
  const increment = tree.props.overlay[0].node.props.onPress;

  invokeCallback(increment);
  await flushEffects();
  renderer.emitFullTree();

  tree = commits.at(-1).data;
  assert.equal(tree.props.overlay[0].node.id, originalOverlayId);
  assert.equal(tree.props.overlay[0].node.props.symbol, "1");

  renderer.render(React.createElement(App, { fill: "#222222" }));
  renderer.emitFullTree();
  tree = commits.at(-1).data;
  assert.equal(tree.props.overlay[0].node.id, originalOverlayId);
  assert.equal(tree.props.overlay[0].node.props.symbol, "1");
});

test("accessory state persists across renders without remounting a nested root", async () => {
  const renderer = createRenderer();
  const commits = [];
  renderer.onCommit((payload) => {
    commits.push(payload);
  });

  function StatefulAccessory() {
    const [symbol, setSymbol] = React.useState("mic");
    return React.createElement("IconButton", {
      symbol,
      onPress: () => {
        setSymbol("mic.fill");
      },
    });
  }

  function App(props) {
    return React.createElement(
      "Input",
      { value: props.value },
      trailingAccessorySlot(React.createElement(StatefulAccessory))
    );
  }

  renderer.render(React.createElement(App, { value: "one" }));
  let tree = commits.at(-1).data;
  const originalAccessoryId = tree.props.trailingAccessory.id;
  const updateAccessory = tree.props.trailingAccessory.props.onPress;

  invokeCallback(updateAccessory);
  await flushEffects();
  renderer.emitFullTree();

  tree = commits.at(-1).data;
  assert.equal(tree.props.trailingAccessory.id, originalAccessoryId);
  assert.equal(tree.props.trailingAccessory.props.symbol, "mic.fill");

  renderer.render(React.createElement(App, { value: "two" }));
  renderer.emitFullTree();
  tree = commits.at(-1).data;
  assert.equal(tree.props.trailingAccessory.id, originalAccessoryId);
  assert.equal(tree.props.trailingAccessory.props.symbol, "mic.fill");
});

test("overlay effects clean up on rerender and unmount", async () => {
  const events = [];
  const renderer = createRenderer();

  function EffectOverlay(props) {
    React.useEffect(() => {
      events.push(`mount:${props.label}`);
      return () => {
        events.push(`cleanup:${props.label}`);
      };
    }, [props.label]);

    return React.createElement("Icon", { symbol: props.label });
  }

  function App(props) {
    return React.createElement(
      "RoundedRect",
      null,
      overlaySlot(React.createElement(EffectOverlay, { label: props.label }))
    );
  }

  renderer.render(React.createElement(App, { label: "one" }));
  await flushEffects();
  renderer.render(React.createElement(App, { label: "two" }));
  await flushEffects();
  renderer.unmount();
  await flushEffects();

  assert.deepEqual(events, [
    "mount:one",
    "cleanup:one",
    "mount:two",
    "cleanup:two",
  ]);
});
