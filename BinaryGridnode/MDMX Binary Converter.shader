Shader "Micca/MDMX Converter"
{
    Properties
    {
        _MainTex ("Input Raw", 2D) = "black" {}
        _InputSelf ("Input Buffer", 2D) = "black" {}
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "PreviewType" = "Plane"}
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"

            //#pragma enable_d3d11_debug_symbols

            #define MAXCHANNELS 4096
            #define SPACINGX 128
            #define SPACINGY 128

            #define BINMAX 2880
            #define BINX 6
            #define BINY 480
            #define CRCBITS 4

            #define MAXVRSLCHANNELS 1536
            #define SPACINGVRSLX 13
            #define SPACINGVRSLY 120

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            sampler2D _InputSelf;
            float4 _InputSelf_ST;

            float _Udon_VRSLToggle;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            inline float2 coordsFromChannel(uint channel) {
                channel--;
                float2 t = float2(floor(channel % SPACINGX),floor(channel / SPACINGX));
                float2 offsets = float2(1./SPACINGX,1./SPACINGY);
            
                t *= offsets;
                t += offsets/2.; //center pixel sample
            
                return t;
            }

            uint getChannel(float2 coord) {
                uint t = 0;
                uint x = floor(coord.x * SPACINGX);
                uint y = floor(coord.y * SPACINGY);
                t = y * 128;
                t += x;

                return t;
            }

            inline float2 coordsFromVRSL(uint channel) {
                //channel--;
                uint universe = channel / 512;
                channel += universe * 8; //VRSL universe spacing

                float2 t = float2(floor(channel % SPACINGVRSLX),floor(channel / SPACINGVRSLX));
                float2 offsets = float2(1./SPACINGVRSLX,1./SPACINGVRSLY);
            
                t *= offsets;
                t += offsets/2.; //center pixel sample
            
                return t;
            }

            //from torvid
            // CRC-4 (x⁴ + x + 1)
            uint Crc4For6(
                uint b0, uint b1, uint b2,
                uint b3, uint b4, uint b5)
            {
                uint crc  = 0u;
                uint poly = 0x03u;

                uint data[6] = { b0, b1, b2, b3, b4, b5 };
                for (int idx = 0; idx < 6; ++idx)
                {
                    for (int bit = 7; bit >= 0; --bit)
                    {
                        uint inBit = (data[idx] >> bit) & 1u;
                        bool top   = (crc >> 3u) & 1u > 0;
                        crc = ((crc << 1) | inBit) & 0xFu;
                        if (top) crc ^= poly;
                    }
                }
                crc = (crc << 4);

                return crc;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                const float columnSpace = 1. / BINY;
                const uint totalBits = BINX * 8 + CRCBITS;
                const float bitSpace = 1. / (float) totalBits;
                const uint bitTable[8] = {128,64,32,16,8,4,2,1}; //slightly faster than bitwise ops for this

                //for multi grid support
                const float2 offsetTable[5] = {
                    float2(0,872./1080.),
                    float2(0,664./1080.),
                    float2(0,456./1080.),
                    float2(0,248./1080.),
                    float2(0,40./1080.),
                };
                const float2 scaleTable[5] = {
                    float2(1.,208./1080.),
                    float2(1.,208./1080.),
                    float2(1.,208./1080.),
                    float2(1.,208./1080.),
                    float2(1.,208./1080.),
                };

                uint channel = getChannel(i.uv);

                //VRSL direct dump
                //Bypasses binary decode and dump direct VRSL blocks
                {
                    if (_Udon_VRSLToggle > 0) {
                        float2 uv = coordsFromVRSL(channel);
                        float2 offset = float2(0,872./1080.);
                        float2 scale = float2(1.,208./1080.);
                        uv.x = 1. - uv.x;
                        float4 col = tex2Dlod(_MainTex, float4(uv.yx * scale + offset,0,0));
                        col.rgb = LinearToGammaSpace(col.rgb);
                        col.a = 1;
                        return col;
                    }
                }

                uint gridId = (channel / 2880);
                channel = channel % 2880;

                float2 offset = offsetTable[gridId];
                float2 scale = scaleTable[gridId];

                uint column = (channel / 6);

                bool discardFlag = false;

                uint values[7] = {0,0,0,0,0,0,0};

                //grabs 6 bytes + 4 bit crc
                //we -must- sample all 6 bytes to calculate the crc
                //also this is why we only have a crc per 6 :) [sample hell otherwise]
                for (uint byte = 0; byte < BINX+1; byte++) {
                    uint bits = byte == 6 ? 4 : 8;
                    for (uint bit = 0; bit < bits; bit++) {
                        float2 uv = float2(column * columnSpace + columnSpace / 2.,(byte * 8 + bit) * bitSpace + bitSpace / 2.);
                        uv.y = 1 - uv.y;
                        bool bitVal = false;
                        float4 samp = tex2Dlod(_MainTex, float4(uv * scale + offset,0,0));

                        if (samp.r < 0.2 && samp.g < 0.2 && samp.b < 0.2) {
                            bitVal = false;
                        } else if (samp.r > 0.8 && samp.g > 0.8 && samp.b > 0.8) {
                            bitVal = true;
                        } else {
                            bitVal = false;
                            discardFlag = true;
                        }

                        if (samp.a < 0.9) {
                            discardFlag = true;
                        }

                        values[byte] += bitVal ? bitTable[bit] : 0;
                    }
                }

                float4 col = (float) values[channel % 6] / 255.;

                uint crcCheck = Crc4For6(values[0],values[1],values[2],values[3],values[4],values[5]);

                if (discardFlag || crcCheck != values[6]) {
                    col = tex2Dlod(_InputSelf, float4(i.uv,0,0));
                    col.gb = 0;
                }

                col.a = 1;

                return col;
            }
            ENDCG
        }
    }
}
