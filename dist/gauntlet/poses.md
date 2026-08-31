# Gauntlet judging poses (frozen after W1 R1)

Render command template:

```
swift run -c release MicroCubeMetal --qa-scene hero --qa-features all --qa-time 4 \
  --qa-camera <POSE> --qa-window-points 1280x800 --qa-drawable 1280x800 \
  --qa-scale 1 --qa-view final --qa-frames 1 --qa-capture dist/gauntlet/captures/<wave>-<round>-<name>.png
```

| Pose | `--qa-camera` | Intent |
|---|---|---|
| vista | `336,117.7,292,-2.77,-0.12` | Highest summit (world 336,292, h=116) looking SW across the island interior to the south coast and open sea horizon |
| shore | `280,54.7,152,-1.57,-0.04` | Standing at the waterline on the south coast, looking west along the beach; sea left, land right |
| fog | `245,87.7,260,0.70,0.02` | Ground level inland, looking NE through fog toward the creature silhouettes and their lights |
| ground | `340,80.7,330,0.0,-0.18` | Eye-level on an open north-facing slope (world 340,330, h=79), terrain detail in the foreground descending toward the north coast |
| shrooms | `280,81.7,278,-1.5708,-0.15` | (added W2 R1) Eye-level beside shroom cluster C1 (world 274,278, h=79), looking west; teal glow pooling on rock, cluster C2 (250,284) visible mid-distance right of center, fog behind |

Eye height = terrainHeight(x,z) + 1.7. Camera forward = (cosPitch·sinYaw, sinPitch, cosPitch·cosYaw); yaw 0 faces +z.
