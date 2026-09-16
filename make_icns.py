"""Package Apple's PNG-based ICNS representations without iconutil dependencies."""
from pathlib import Path
import struct
root=Path(__file__).parent/'build'
chunks=[]
for kind,name in [('icp4','16x16'),('icp5','32x32'),('icp6','32x32@2x'),('ic07','128x128'),('ic08','256x256'),('ic09','512x512'),('ic10','512x512@2x'),('ic11','16x16@2x'),('ic12','32x32@2x'),('ic13','128x128@2x'),('ic14','256x256@2x')]:
    data=(root/'MMM.iconset'/f'icon_{name}.png').read_bytes()
    chunks.append(kind.encode()+struct.pack('>I',len(data)+8)+data)
body=b''.join(chunks)
(root/'MMM.app/Contents/Resources/MMM.icns').write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
