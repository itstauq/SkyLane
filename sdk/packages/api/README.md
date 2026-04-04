# @notchapp/api

Component API for building NotchApp widgets.

Install with:

```bash
npm install @notchapp/api
```

Use it in a widget:

```tsx
import { Button, Stack, Text, useLocalStorage } from "@notchapp/api";

export default function Widget({ environment }) {
  const [count, setCount] = useLocalStorage("count", 0);

  console.info(`render hello widget span=${environment.span} count=${count}`);

  return (
    <Stack spacing={10}>
      <Text>Hello from NotchApp</Text>
      <Text tone="secondary">{`Span ${environment.span} • Count ${count}`}</Text>
      <Button title="Increment" onPress={() => setCount((value) => value + 1)} />
    </Stack>
  );
}
```

Current exports:

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
- `LocalStorage`
- `getPreferenceValues`
- `useLocalStorage`
- `usePromise`
- `useFetch`
- `openURL`

Widget preferences can be declared in your widget manifest under `notch.preferences` and read at runtime:

```tsx
import { getPreferenceValues } from "@notchapp/api";

export default function Widget() {
  const preferences = getPreferenceValues();
  return <Text>{preferences.mailbox ?? "Inbox"}</Text>;
}
```

The SDK source and examples live in the main repository:

<https://github.com/itstauq/NotchApp>

Local widget images live under your package `assets/` directory and can be referenced with paths like `src="assets/cover.png"`.

`Image` supports both local package assets and remote image URLs. `contentMode="fill"` is the default, and `contentMode="fit"` keeps the full image visible inside its frame.

Remote image notes:

- widgets use `https://` URLs only
- remote images are fetched by the host, not inside the widget runtime
- custom headers, cookies, and auth are not supported yet
