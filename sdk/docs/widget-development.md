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
- any state it needs through normal React hooks or `@notchapp/api` hooks

Example:

```tsx
import { Button, Stack, Text, useLocalStorage } from "@notchapp/api";

export default function Widget({ environment, logger }) {
  const [count, setCount] = useLocalStorage("count", 0);

  logger.info(`render span=${environment.span} count=${count}`);

  return (
    <Stack spacing={10}>
      <Text>Hello from NotchApp</Text>
      <Text tone="secondary">{`Span ${environment.span} • Count ${count}`}</Text>
      <Button title="Increment" onPress={() => setCount((value) => value + 1)} />
    </Stack>
  );
}
```

Use normal React state for transient UI state. Use `useLocalStorage` when the state should persist across widget reloads.

The render function receives:

- `environment`
- `logger`

`environment.span` is the most useful field in practice. Use it to make your widget width-responsive and adapt to narrow or wide layouts.

Widget callbacks receive payload objects when the component provides one:

- `Button`, `Row`, `Checkbox`, and `IconButton` use `onPress`
- `Input` uses `onChange` and `onSubmit`, and those callbacks receive `{ value }`

Current `Image` support is limited to package-local assets such as `src="assets/cover.png"`. It supports `contentMode="fill"` by default and `contentMode="fit"` when you want the entire image visible. Remote image URLs come later.

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

Current validation rules:

- `id` and `title` must be non-empty
- `minSpan` and `maxSpan` must be integers
- `minSpan` must be greater than `0`
- `maxSpan` must be greater than or equal to `minSpan`
- the entry file must exist
- the host currently supports up to `12` columns

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

The fastest references are the starter widget in [sdk/examples/hello](/Users/tauquir/Projects/NotchApp2/sdk/examples/hello) and the local image example in [sdk/examples/local-image](/Users/tauquir/Projects/NotchApp2/sdk/examples/local-image).

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

`Image` currently supports:

- `src`
- `contentMode="fill"` (default)
- `contentMode="fit"`
