# Widget Development

Build widgets for NotchApp with `notchapp` and `@notchapp/api`.

This guide is intentionally focused on the day-to-day widget author workflow: create, develop, hot reload, and use the widget API.

## Develop a Widget

### Create a widget package

Widgets can live anywhere. A widget is just a package with:

- a `package.json`
- a `src/index.tsx` entry file
- a `notch` manifest in `package.json`

Example:

```text
my-widget/
  package.json
  src/
    index.tsx
```

Example `package.json`:

```json
{
  "name": "@acme/notchapp-widget-hello",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "notchapp develop",
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
    "description": "Example widget",
    "icon": "sparkles",
    "minSpan": 3,
    "maxSpan": 6,
    "entry": "src/index.tsx"
  }
}
```

### Start development

From the widget directory:

```bash
npx notchapp develop
```

Or with scripts:

```bash
npm run dev
```

What happens in development:

- your widget is built into `.notch/build/index.cjs`
- the widget is registered with NotchApp
- file changes trigger rebuilds automatically
- the app hot-reloads the updated widget

That is the main development loop.

### Build and lint

```bash
npx notchapp build
npx notchapp lint
```

Or:

```bash
npm run build
npm run lint
```

`lint` currently validates the widget manifest and entry file.

## Widget Manifest

Each widget declares a `notch` block in `package.json`.

Required fields:

- `id`: stable widget identifier, usually reverse-DNS style
- `title`: display name
- `icon`: SF Symbol name
- `minSpan`: minimum width in columns
- `maxSpan`: maximum width in columns

Optional fields:

- `description`: short description
- `entry`: entry file path, defaults to `src/index.tsx`

Current rules:

- `id` and `title` must be non-empty
- `minSpan` and `maxSpan` must be integers
- `minSpan` must be greater than `0`
- `maxSpan` must be greater than or equal to `minSpan`
- the entry file must exist
- the host currently supports up to `12` columns

## Write a Widget

Example:

```tsx
import { Button, Stack, Text } from "@notchapp/api";

export const initialState = {
  count: 0,
};

export const actions = {
  increment(state) {
    return {
      ...state,
      count: (state?.count ?? 0) + 1,
    };
  },
};

export default function Widget({ environment, state, logger }) {
  logger.info(`render span=${environment.span} count=${state.count}`);

  return (
    <Stack spacing={10}>
      <Text>Hello from NotchApp</Text>
      <Text tone="secondary">{`Span ${environment.span} • Count ${state.count}`}</Text>
      <Button title="Increment" action="increment" />
    </Stack>
  );
}
```

## Widget API

Each widget module can export:

- `default`: required render function
- `initialState`: optional initial state object
- `actions`: optional action handlers

### Render function

Your default export receives:

- `environment`
- `state`
- `logger`

Example shape:

```ts
type WidgetRenderProps = {
  environment: RuntimeEnvironment;
  state: any;
  logger: {
    log: (...parts: any[]) => void;
    info: (...parts: any[]) => void;
    warn: (...parts: any[]) => void;
    error: (...parts: any[]) => void;
  };
};
```

### State

`initialState` is used the first time a widget instance mounts.

Actions can return a new state object:

```ts
export const actions = {
  setDraft(state, context) {
    return {
      ...state,
      draft: context?.payload?.value ?? "",
    };
  },
};
```

If an action returns `undefined`, the current state is kept.

### Action context

Actions receive:

- `environment`
- `logger`
- `payload`

Current payload shape:

```ts
type RuntimeActionPayload = {
  value?: string;
  id?: string;
};
```

## Runtime Environment

Widgets currently receive:

```ts
type RuntimeEnvironment = {
  widgetId: string;
  instanceId: string;
  viewId: string;
  span: number;
  hostColumnCount: number;
  isEditing: boolean;
  isDevelopment: boolean;
};
```

The most useful field in practice is usually `environment.span`, so widgets can adapt to narrow or wide layouts.

## Components

`@notchapp/api` currently supports:

- `Stack`
- `Inline`
- `Row`
- `Text`
- `Icon`
- `IconButton`
- `Checkbox`
- `Input`
- `Button`

### `Stack`

Vertical container.

Props:

- `id?: string`
- `spacing?: number`
- `children`

### `Inline`

Horizontal container.

Props:

- `id?: string`
- `spacing?: number`
- `children`

### `Row`

Tappable full-width row.

Props:

- `id?: string`
- `action?: string | null`
- `payload?: { value?: string; id?: string } | null`
- `children`

### `Text`

Text label.

Props:

- `id?: string`
- `text?: string`
- `role?: string`
- `tone?: "primary" | "secondary" | "tertiary"`
- `lineClamp?: number`
- `strikethrough?: boolean`
- `children`

### `Icon`

SF Symbol icon.

Props:

- `id?: string`
- `symbol?: string`
- `icon?: string`
- `name?: string`
- `tone?: "primary" | "secondary" | "tertiary"`

### `IconButton`

Compact icon action button.

Props:

- `id?: string`
- `symbol?: string`
- `icon?: string`
- `name?: string`
- `action?: string | null`
- `payload?: { value?: string; id?: string } | null`
- `tone?: "primary" | "secondary" | "tertiary"`
- `disabled?: boolean`

### `Checkbox`

Checkbox control.

Props:

- `id?: string`
- `checked?: boolean`
- `action?: string | null`
- `payload?: { value?: string; id?: string } | null`

### `Input`

Single-line text input.

Props:

- `id?: string`
- `value?: string`
- `placeholder?: string`
- `changeAction?: string | null`
- `submitAction?: string | null`
- `leadingAccessory?: RenderNode`
- `trailingAccessory?: RenderNode`

Behavior:

- `changeAction` fires with `{ value }`
- `submitAction` fires on Return with `{ value }`

### `Button`

Full-width button.

Props:

- `id?: string`
- `title?: string`
- `action?: string | null`
- `payload?: { value?: string; id?: string } | null`
- `children`

## Hot Reload

`notchapp develop` is the recommended way to build widgets.

It is designed for the normal authoring loop:

1. Run `npx notchapp develop`
2. Edit files in `src/` or `package.json`
3. Let the widget rebuild automatically
4. See the widget update in NotchApp

## Example Widgets

Examples in this repo:

- `widget-runtime/widgets/com.notchapp.hello`
- `widget-runtime/widgets/com.notchapp.capture`

## Current Limitations

- `lint` is manifest validation only
- the host currently supports a 12-column layout
- there is no built-in persistence API yet
