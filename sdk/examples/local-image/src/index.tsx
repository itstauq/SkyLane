import { Image, RoundedRect, Stack, Text } from "@notchapp/api";

export default function Widget() {
  return (
    <Stack spacing={10}>
      <RoundedRect
        fill="#0f172a"
        frame={{ maxWidth: "infinity", height: 64 }}
        clipShape={{ type: "roundedRect", cornerRadius: 18 }}
      >
        <Image src="assets/cover.png" contentMode="fit" />
      </RoundedRect>
      <Text>Bundled local asset</Text>
      <Text tone="secondary">Loaded from assets/cover.png</Text>
    </Stack>
  );
}
