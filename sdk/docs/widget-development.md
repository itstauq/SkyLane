# Widget Development

Build widgets for NotchApp with `notchapp` and `@notchapp/api`.

The day-to-day workflow is simple: install the SDK in your widget package, run `npx notchapp dev`, and let NotchApp hot-reload your widget while you edit.

## Install

Create a widget package and install the SDK:

```bash
npm install --save-dev notchapp
npm install @notchapp/api
```

Minimal layout:

```text
my-widget/
  package.json
  assets/
  src/
    index.tsx
```

Example `package.json`:

```json
{
  "name": "@acme/notchapp-widget-hello",
  "private": true,
  "scripts": {
    "dev": "notchapp dev",
    "build": "notchapp build",
    "lint": "notchapp lint"
  },
  "devDependencies": {
    "notchapp": "^0.1.0"
  },
  "dependencies": {
    "@notchapp/api": "^0.1.0"
  },
  "notch": {
    "id": "com.acme.hello",
    "title": "Hello",
    "icon": "sparkles",
    "minSpan": 3,
    "maxSpan": 6,
    "entry": "src/index.tsx"
  }
}
```

## Develop

Run this inside your widget directory:

```bash
npx notchapp dev
```

Or:

```bash
npm run dev
```

`notchapp dev` is the main development workflow. It:

- builds your widget into `.notch/build/index.cjs`
- copies package-local assets into `.notch/build/assets`
- registers the local widget with NotchApp for development
- watches `package.json`, `src/`, and `assets/`
- rebuilds and reloads the widget whenever you save changes
- prints build output in the terminal

That means the normal loop is just:

1. run `npx notchapp dev`
2. edit your widget
3. save
4. see the updated widget in NotchApp

## Build

Create a production build with:

```bash
npx notchapp build
```

## Lint

Validate the widget manifest and entry file with:

```bash
npx notchapp lint
```

## Write a Widget

Each widget needs:

- a `default` export that renders the widget
- a `notch` manifest in `package.json`
- any state it needs through normal React hooks or `@notchapp/api`

Example:

```tsx
import { Button, Stack, Text, LocalStorage } from "@notchapp/api";

export default function Widget({ environment }) {
  const count = LocalStorage.getItem("count") ?? 0;

  console.info(`render span=${environment.span} count=${count}`);

  return (
    <Stack spacing={10}>
      <Text>Hello from NotchApp</Text>
      <Text tone="secondary">{`Span ${environment.span} • Count ${count}`}</Text>
      <Button
        title="Increment"
        onPress={() => LocalStorage.setItem("count", count + 1)}
      />
    </Stack>
  );
}
```

Use normal React state for transient UI state. Use `LocalStorage` when the state should persist across widget reloads.

The render function receives:

- `environment`

`environment.span` is the most useful field in practice. Use it to make your widget width-responsive and adapt to narrow or wide layouts.

Widget callbacks receive payload objects when the component provides one:

- `Button`, `Row`, `Checkbox`, and `IconButton` use `onPress`
- `Input` uses `onChange` and `onSubmit`, and those callbacks receive `{ value }`

`Image` supports both package-local assets such as `src="assets/cover.png"` and remote image URLs. It uses `contentMode="fill"` by default and supports `contentMode="fit"` when you want the entire image visible.

## Preferences

Widget preferences are host-managed configuration values defined in the widget manifest and edited per widget instance inside NotchApp.

This stays intentionally close to Raycast:

- preferences are declared under `notch.preferences`
- values are read with `getPreferenceValues()`
- values are resolved before widget code sees them
- required preferences block normal widget rendering until configured

Preference values are resolved in this order:

1. saved value for this widget instance
2. manifest `default`
3. `undefined`

That means preferences are:

- per widget instance
- separate from `LocalStorage`
- meant for user configuration, not internal widget state

Example:

```tsx
import { getPreferenceValues, Image, RoundedRect, Stack, Text } from "@notchapp/api";

export default function Widget() {
  const preferences = getPreferenceValues<{
    imageUrl?: string;
    title?: string;
  }>();

  return (
    <Stack spacing={10}>
      <RoundedRect
        fill="#0f172a"
        frame={{ maxWidth: "infinity", height: 112 }}
        clipShape={{ type: "roundedRect", cornerRadius: 18 }}
      >
        <Image src={preferences.imageUrl} contentMode="fit" />
      </RoundedRect>
      <Text>{preferences.title ?? "Remote image"}</Text>
      <Text tone="secondary">Configured through widget preferences</Text>
    </Stack>
  );
}
```

### Supported Preference Fields

Use the Raycast field names exactly:

- `name`
- `title`
- `description`
- `type`
- `required`
- `placeholder`
- `default`
- `label` for `checkbox`
- `data` for `dropdown`

Supported preference `type` values today:

- `textfield`
- `password`
- `checkbox`
- `dropdown`

### Required Preferences

If a preference has `required: true` and still resolves to no usable value:

- the widget does not render normally in the notch
- NotchApp shows a host `Configuration Required` state
- the user can open that widget instance’s settings from there

For required text-like fields:

- empty strings are treated as missing

Optional fields without a saved value or default resolve to `undefined`.

## Manifest

Each widget declares a `notch` block in `package.json`.

Required fields:

- `id`
- `title`
- `icon`
- `minSpan`
- `maxSpan`

Optional fields:

- `description`
- `entry` default: `src/index.tsx`
- `preferences`

Current validation rules:

- `id` and `title` must be non-empty
- `minSpan` and `maxSpan` must be integers
- `minSpan` must be greater than `0`
- `maxSpan` must be greater than or equal to `minSpan`
- the entry file must exist
- the host currently supports up to `12` columns

Extended example with preferences:

```json
{
  "name": "@acme/notchapp-widget-remote-image",
  "private": true,
  "scripts": {
    "dev": "notchapp dev",
    "build": "notchapp build",
    "lint": "notchapp lint"
  },
  "devDependencies": {
    "notchapp": "^0.1.0"
  },
  "dependencies": {
    "@notchapp/api": "^0.1.0"
  },
  "notch": {
    "id": "com.acme.remote-image",
    "title": "Remote Image",
    "description": "Remote image example",
    "icon": "network",
    "minSpan": 3,
    "maxSpan": 12,
    "entry": "src/index.tsx",
    "preferences": [
      {
        "name": "imageUrl",
        "title": "Image URL",
        "description": "HTTPS image URL to display in the widget.",
        "type": "textfield",
        "placeholder": "https://example.com/image.png",
        "required": true
      },
      {
        "name": "caption",
        "title": "Caption",
        "type": "textfield",
        "default": "Remote image"
      },
      {
        "name": "fitImage",
        "title": "Fit Image",
        "label": "Show the full image",
        "type": "checkbox",
        "default": true
      },
      {
        "name": "theme",
        "title": "Theme",
        "type": "dropdown",
        "default": "dark",
        "data": [
          { "title": "Dark", "value": "dark" },
          { "title": "Light", "value": "light" }
        ]
      }
    ]
  }
}
```

## Components

`@notchapp/api` currently exports:

- `Stack`
- `Inline`
- `Spacer`
- `Text`
- `Icon`
- `Image`
- `Button`
- `Row`
- `IconButton`
- `Checkbox`
- `Input`
- `ScrollView`
- `Divider`
- `Circle`
- `RoundedRect`

The fastest references are the starter widget in [sdk/examples/hello](/Users/tauquir/Projects/NotchApp2/sdk/examples/hello), the local image example in [sdk/examples/local-image](/Users/tauquir/Projects/NotchApp2/sdk/examples/local-image), and the remote image example in [sdk/examples/remote-image](/Users/tauquir/Projects/NotchApp2/sdk/examples/remote-image).

## LocalStorage vs Preferences

Use `LocalStorage` for widget-owned persisted state such as:

- cached counters
- dismissed UI state
- local widget data

Use manifest preferences for user-configured values such as:

- API tokens
- account IDs
- user-chosen labels
- display modes

Important differences:

- `LocalStorage` is widget code controlled
- preferences are host controlled
- `LocalStorage.allItems()` does not include preference values
- preference values are available synchronously through `getPreferenceValues()`

## Local Images

For local widget images, place files under your package `assets/` directory and reference them with package-relative paths:

```tsx
import { Image, RoundedRect } from "@notchapp/api";

export default function Widget() {
  return (
    <RoundedRect frame={{ width: 56, height: 56 }} clipShape={{ type: "roundedRect", cornerRadius: 14 }}>
      <Image src="assets/cover.png" contentMode="fit" />
    </RoundedRect>
  );
}
```

`notchapp build` and `notchapp dev` copy `assets/` into `.notch/build/assets`, so `src="assets/cover.png"` works in both local development and packaged widget installs.

## Remote Images

Remote image URLs are fetched by the host image pipeline, not by widget code.

- widgets can use `https://` remote image URLs
- remote image requests are anonymous and do not support custom headers, cookies, or auth yet
- if the URL should be user-configurable, prefer a required manifest preference plus `getPreferenceValues()`

Example:

```tsx
import { getPreferenceValues, Image, RoundedRect } from "@notchapp/api";

export default function Widget() {
  const preferences = getPreferenceValues<{
    imageUrl?: string;
  }>();

  return (
    <RoundedRect frame={{ width: 72, height: 72 }} clipShape={{ type: "roundedRect", cornerRadius: 18 }}>
      <Image src={preferences.imageUrl} contentMode="fit" />
    </RoundedRect>
  );
}
```

`Image` currently supports:

- `src`
- `contentMode="fill"` (default)
- `contentMode="fit"`

## Configure in NotchApp

Widget preferences are edited inside NotchApp:

1. open Settings
2. go to `Widgets`
3. select the widget instance from the mirrored panel preview
4. open the `Configuration` tab
5. update the instance-specific preferences

Text and password fields save on Enter or when focus leaves the field. Toggles and dropdowns save immediately.

## Troubleshooting

If the widget shows `Configuration Required`:

- make sure all required preferences are filled in
- for required text or password fields, an empty string still counts as missing
- check that dropdown defaults or saved values exist in the declared `data`

If a remote image does not load:

- make sure the URL is `https://`
- make sure the response is actually an image

If `notchapp lint` fails:

- verify the `notch` manifest block exists
- verify `entry` points to a real file
- verify preference definitions use supported field names and types
