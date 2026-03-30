const React = require("react");
const { useLocalStorage } = require("./hooks/useLocalStorage");
const { usePromise } = require("./hooks/usePromise");
const { useFetch } = require("./hooks/useFetch");
const { openURL } = require("./functions/openURL");
const { LocalStorage } = require("./runtime");

const OVERLAY_SLOT_TYPE = "__notch_overlay";
const LEADING_ACCESSORY_SLOT_TYPE = "__notch_leadingAccessory";
const TRAILING_ACCESSORY_SLOT_TYPE = "__notch_trailingAccessory";

function slot(type, props, children, key) {
  return React.createElement(
    type,
    key == null ? props : { ...(props ?? {}), key },
    children
  );
}

function normalizeOverlayChildren(overlay) {
  if (overlay == null || overlay === false) {
    return [];
  }

  if (Array.isArray(overlay)) {
    return overlay.flatMap(normalizeOverlayChildren);
  }

  if (React.isValidElement(overlay)) {
    return [slot(OVERLAY_SLOT_TYPE, { alignment: "center" }, overlay, overlay.key)];
  }

  if (typeof overlay === "object") {
    const node = overlay.element ?? overlay.node;
    if (node != null) {
      return [
        slot(
          OVERLAY_SLOT_TYPE,
          { alignment: typeof overlay.alignment === "string" ? overlay.alignment : "center" },
          node,
          overlay.key ?? node.key
        ),
      ];
    }
  }

  return [];
}

function normalizeAccessoryChild(type, accessory) {
  if (accessory == null || accessory === false) {
    return [];
  }

  return [slot(type, null, accessory)];
}

function createHostElement(type, rawProps = {}) {
  const {
    children,
    overlay,
    leadingAccessory,
    trailingAccessory,
    ...props
  } = rawProps;
  const hostChildren = [];

  if (children !== undefined) {
    hostChildren.push(children);
  }

  hostChildren.push(...normalizeOverlayChildren(overlay));
  hostChildren.push(...normalizeAccessoryChild(LEADING_ACCESSORY_SLOT_TYPE, leadingAccessory));
  hostChildren.push(...normalizeAccessoryChild(TRAILING_ACCESSORY_SLOT_TYPE, trailingAccessory));

  return React.createElement(type, props, ...hostChildren);
}

function Stack(props = {}) {
  return createHostElement("Stack", props);
}

function Inline(props = {}) {
  return createHostElement("Inline", props);
}

function Spacer(props = {}) {
  return createHostElement("Spacer", props);
}

function Text(props = {}) {
  return createHostElement("Text", props);
}

function Icon(props = {}) {
  return createHostElement("Icon", props);
}

function Image(props = {}) {
  return createHostElement("Image", props);
}

function Button(props = {}) {
  return createHostElement("Button", props);
}

function Row(props = {}) {
  return createHostElement("Row", props);
}

function IconButton(props = {}) {
  return createHostElement("IconButton", props);
}

function Checkbox(props = {}) {
  return createHostElement("Checkbox", props);
}

function Input(props = {}) {
  return createHostElement("Input", props);
}

function ScrollView(props = {}) {
  return createHostElement("ScrollView", props);
}

function Divider(props = {}) {
  return createHostElement("Divider", props);
}

function Circle(props = {}) {
  return createHostElement("Circle", props);
}

function RoundedRect(props = {}) {
  return createHostElement("RoundedRect", props);
}

module.exports = {
  Stack,
  Inline,
  Spacer,
  Text,
  Icon,
  Image,
  Button,
  Row,
  IconButton,
  Checkbox,
  Input,
  ScrollView,
  Divider,
  Circle,
  RoundedRect,
  LocalStorage,
  useLocalStorage,
  usePromise,
  useFetch,
  openURL,
};
