# @notchapp/api

Component API for building NotchApp widgets.

Install with:

```bash
npm install @notchapp/api
```

Use it in a widget:

```tsx
import { Button, Stack, Text, useLocalStorage } from "@notchapp/api";

export default function Widget({ environment, logger }) {
  const [count, setCount] = useLocalStorage("count", 0);

  logger.info(`render hello widget span=${environment.span} count=${count}`);

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
- `useLocalStorage`
- `usePromise`
- `useFetch`
- `openURL`

The SDK source and examples live in the main repository:

<https://github.com/itstauq/NotchApp>

Local widget images live under your package `assets/` directory and can be referenced with paths like `src="assets/cover.png"`.

`Image` supports `contentMode="fill"` by default and `contentMode="fit"` when the image should stay fully visible inside its frame. Remote image URLs are not part of the current surface yet.
