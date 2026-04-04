import {
  Button,
  Camera,
  Circle,
  Divider,
  Icon,
  Menu,
  RoundedRect,
  getPreferenceValues,
  listCameras,
  setPreferenceValue,
  selectCamera,
  usePromise,
} from "@notchapp/api";
import { useEffect, useState } from "react";

function CameraOverlayBadge({ symbol, padding }) {
  return (
    <RoundedRect
      cornerRadius={10}
      fill="#00000047"
      width={28}
      height={24}
      padding={padding}
    >
      <Icon symbol={symbol} size={10} weight="bold" color="#FFFFFF" opacity={0.82} />
    </RoundedRect>
  );
}

export default function Widget() {
  const preferences = getPreferenceValues();
  const { data: cameras = [], revalidate } = usePromise(() => listCameras(), []);
  const [mirrorPreview, setMirrorPreview] = useState(preferences.mirrorPreview ?? true);

  useEffect(() => {
    setMirrorPreview(preferences.mirrorPreview ?? true);
  }, [preferences.mirrorPreview]);

  return (
    <Camera
      deviceId={preferences.cameraDeviceId}
      mirrored={mirrorPreview}
      frame={{ maxWidth: Infinity, maxHeight: Infinity }}
      clipShape={{ type: "roundedRect", cornerRadius: 16 }}
      background="#1e232b"
      overlay={[
        {
          alignment: "topTrailing",
          node: (
            <Menu label={<CameraOverlayBadge symbol="gearshape.fill" padding={12} />}>
              {cameras.length === 0 ? (
                <Button disabled>Loading Cameras…</Button>
              ) : (
                cameras.map((camera) => (
                  <Button
                    key={camera.id}
                    checked={camera.selected}
                    onPress={async () => {
                      await selectCamera(camera.id);
                      revalidate();
                    }}
                  >
                    {camera.name}
                  </Button>
                ))
              )}
              <Divider />
              <Button
                checked={mirrorPreview}
                onPress={async () => {
                  const nextValue = !mirrorPreview;
                  setMirrorPreview(nextValue);
                  await setPreferenceValue("mirrorPreview", nextValue);
                  console.info("camera menu: mirror preview", nextValue);
                }}
              >
                Mirror Preview
              </Button>
            </Menu>
          ),
        },
      ]}
    />
  );
}
