// Golden protocol samples.
//
// Frozen frames as peers send them. They must keep decoding the same way:
// a change that breaks one of these breaks talking to phones that are not
// updated yet. Never edit a sample to make a test pass - add a new one for
// a new format and keep the old one as long as such peers may exist.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';
const String _bob = '200:aaaa:bbbb:cccc:dddd:eeee:ffff:1111';

/// A ping as 1.10.0 sends it to a friend: hello digests, no version.
const String _ping110 = '{"type":"ping","mf":"3f2a9c1d","ms":0}';

/// A ping from 1.11 on: the same plus `ver` / `build` / `caps`.
const String _ping111 =
    '{"type":"ping","ver":"1.11.0","build":11,'
    '"caps":["ledger1","relay1","group_call1","disappear1","meet1"],'
    '"mf":"3f2a9c1d","mk":"0b7e","ms":1790000000000}';

/// A pong as 1.10.0 sends it.
const String _pong110 = '{"type":"pong","state":"foreground","ms":0}';

/// A pong from 1.11 on.
const String _pong111 =
    '{"type":"pong","state":"background","ver":"1.11.0","build":11,'
    '"caps":["ledger1","relay1"],"ms":0}';

const String _message =
    '{"type":"message","msgId":"m-golden-1","text":"Cześć, to próbka",'
    '"createdAt":"2026-09-21T14:13:20.000Z","ttl":3600}';

const String _groupInvite =
    '{"type":"group_invite","groupId":"g-golden","groupName":"Paczka",'
    '"description":"Wspólne wyjście","avatarPreset":"zen_avatar_2",'
    '"memberAddresses":["$_ada","$_bob"],"senderName":"Ada",'
    '"inviteId":"inv-golden-1"}';

/// A signed ledger entry (feed post), as replicated between devices, and
/// its device certificate, which travels apart (once per device). Made by
/// the bridge's `cmd/zensig` from fixed seeds (SHA-256 of
/// "zen-golden-account" and "zen-golden-device"), so the signatures and the
/// id never change. The entry's signature names the device's ML-DSA key by
/// fingerprint (3405 bytes); the certificate publishes that key and is
/// signed by the account in the keyed form (5325 bytes).
const String _goldenDevicePqKey =
    'wAfIwBexgktLnhGavryorX_albRJXn9lhp0MYTW5XO-dJ6Fc_i0xSPatzLSAFXzpTJ03'
    'RsHfOD9QC7ke8Me0Uxvg3YP_zsh42C09I61GM5cqQUBadELdoiLPGSIhgkt4OnZVu4V0'
    'FY5A8bHWmu0FRffb_Kxedi3hiG-YnA5a0k5ORjn09181KafhRWaQ85mNW62X5DcA0T_5'
    'iP2gIzcDMjMjyRMap1R5tZUl3x4nfv_N8d_uHb54j2ePp29_Woo0enNHXChMhwPo-Crk'
    'Wfm5IgcUeOrxBdxFG04KnC17vxWJfVrYzcJQ6zyCxbiv4rxksKHmDM2XCF8F_hR9B_1I'
    'B63ija4xAGd63LyUh5_B9uZtjeYm8zgXWmFIgbwzEyoHFx8-IfbGtA2YxeCCKE7DuvaJ'
    'kAJe3HhCk8M9YVVztfglcmBBHlGMjZyQITeJ6I5LHCF6ueh-4rmWwG__TUb_tIquZIMh'
    'ExfR9rVC9iessyzGXdQOHCkPvL_0f7t2fjpEU5yzxNiqeDU8kkX2y2saoWM2okxH994G'
    'PicTKCZx8RkxtSRf-El9NtIS55AbvjtT2SLMk68WlaL284BwJbE96aKxwJCHrWmqNgig'
    'MXzysyQM6uS3_hqVLGBK7zFeWkz7_nANx8zf4W_6mIG0AVKBHyl18LGiODM-PeCu7IeL'
    'TDzimvJwaXJjlmNqg26A02a4YYfq5hW6k2xsDdCZAZGLCvBejUX2dSWiQJRsMOID8uFf'
    '8wMCUnvGEfMbJmNKdQXd80quYfwwgSGe3ECnfK2m76j3ipCB_WD1ga6ZsAdFTcMGekSU'
    'jMiJdpX6Ta5e6AZsw57DbtA-pH_mbW0ns_i7Wh3Ry0gxYIR2Sdkg0S_FCA3spXYBL7eD'
    'ERCHyxQXlE1aLKJVORqVrqF1g3qO24kcFRXBU68Xgbol2DTumO-kyfT8w_ptd2mx2KCp'
    'g_SZj1Xqo_rDWycrVcdBm5jBlkGIqXNmX5Noh20rNsMoqtwL_gSUtyrdvkx84tPDWfWA'
    'JPI3FGaVewj71GPNr4M_utCY_unxjVLAHxIGVpDqo2X0S6jLX2LRQYY2B6yvr63Epp26'
    'klanXE-nMZsjClY718KNWagW7-iVKSjVWbGm8eDZ8cAeJ9cpC053SPRdojYpbvG496Ql'
    'gh9komGulCKYMk9mbYwGVmBQjzUh98z3rWAbLl_GixFnV-2nXz_indAUw0SZWN28HJE7'
    'sw0QKfQEOblAldJBQiXguV2qrqNE5rItaMLouQzBE5Ba3b8sNvXV4snwwCEJsMfvsBYp'
    'sNDsyySWFIZOjwlVqV-pLuB_fkx7tXIAZqyyW8JWW6GNIlwpfdwQNPvqzp_HcoyO-mpt'
    'CnNhIbnYV8FWVq6nEUBcSx9m5xqxZ_4bZ_4T--Mu91DRah1_0yh1tXnf9L_UZeh7nIN5'
    '4T4f9Xnv0r9rLvPNnadRh_UfH3hR3uiT0_b9W5iK2gr2tON21lNU6zXJ81BAFBOmYNhN'
    'GOxgU811imKdLCS3zrLoUqTx9RrSvqB7a_VLBxbOH_Iy7vNo4v157r8qwu9J1UmHaEVC'
    'KR7cfu_VpTlvZHwz699GmiA8cm0BqyG5ABxzdFeduPTLesi6Um1GjtJ5SHs_3F3Px_V2'
    'v1dkDSHHqB3DhHPEHVRmT8ZrsFnBJHnaNh5ikrz8jFSkN7y4TL958Gpm5W81fwe6p6z7'
    '88UvAZYwUwrKpS22Y3AR8o1buQaBDkqAF0fVWyKxzUYuHXU0YP_kSS3fP-eQv3CiyWzC'
    'fNMiAwzkqQiNNUAEmGwvNeF9ygxch0ZOP0xdrLZSC3H3t_c-9x5pQNSz-FdzR1bAhBQF'
    '0vco_x4hSrULo3v_KldMJzuO-_rDowfL7MgPVLiiAtHS7OXw0nlJLt9IyrHbFZO0ezGJ'
    'Rt-B7BKhlhslalQsZzuczFlc-ONX-z7QsPhkkeirVvm1eilBAqZR5G19y7mViIYgZ9OP'
    'AClmURUixrHTvlQ5zB0Aqrk_oCUE9s4OJpmrMsOIeqE_meIX7xMxZROWUC6Qf3gBo-5T'
    'iavBaDdbIQzv4bRgqnwK47Vi2-qGfZsVtS_Oo8Exp2LXdGyABCNzwyo2R3xyFP5Z4UaL'
    'NURhOlaIJWyr8NdctUf-4oeN-Km2ltwiaXB3jurZpnARWlsqup2JcBwY7URK6G_Bnpxc'
    'NfukxTRJwh7868xbWLIOc4HbMq59CAdjmUvCXbV7NEJy1JLcwry5R_tFSbXbie2EK5m5'
    'cL2fKE11YFtCzr3y6ZGPb805sG216-PRu_LTGZKNXza_AKIVAE2980WqCW6rw7ODPWIc'
    'm4jkW_lKNuJd_PfV3pmIZSHHeCPZ2i0pPbK-1pMOY9ZLO8k7muu51-aauNaodaY-_jOj'
    'ePL5I2t0JJaDAj8DzxzaG5KnXoOwR11s-Cxay-X93RyKqTjf7HF7VO3g7FUveAFsUmnT'
    'XKb0xgUmIPeV4lvXtcd95Lz6NtxxXU5_P4GG5_EGqm2xHBsGM_rLC69UurI_RxpZFr3I'
    'tY7FtQIdUWHdzl81Mjj2y4QECp3KuI0Tn2zU-HwoxfjzbD-5oOglpdFDoQi5VTESgAhg'
    'KLIbrK1rGnF-GLc6TFw=';

const String _goldenCertSig =
    'UArwQUynPMTLYp-acQdwgeN_ccmWdI1-Dv4CQ-zqv8PRDtK6iFMTB5LiDirAEs81G1hH'
    'StPZ1MBh7-bkzksBDcD9JEK-ZWuX9Ct4FJ206mXzLlpf5B_lNIk-tw540Erxf2WkdKlk'
    'H2LGvzAB_oSTtLd65S4z7V0CFq3rGV61A9ZCcVqVuwYf3CToPFf8wmG7Fcd7c8kKtqHb'
    'OWfsfhT25XXbPzsSc1-bdt3pvBcd8dq26K81elPT4GUpJBLILijeIawd-02b_z45B8RA'
    'ldGzt7eZqjUIcSpcr_ntOLTkEQs7d7ruxGYpjqEvo424SEp9f3gphd4oRPRu7Kw9hKAY'
    'K1io4_jJZaKHSgcGy_Th7fR4P3KU5bQdH7trE2PMuIlhSk3TpztWvCMnrqmRctxWr6Sf'
    'pC8NFxNs56NJSSjFqmNa14cYEiwuwc7aiBkaawTqf3JS1fzkK34l6VewEhiTya8iUBeF'
    '2QL0XeMsVhNPUGqRC5q1co5N8vT0HFfKT8_2VRfOI6lquORKJ9xLGSGe7APQFdshL30h'
    'LuZjcJzA2EsdGcmRsCHkVMUeI3CVavHZgoJYe5sEHuiWhj1GxQSIS2-BVsmX3GVJSsdA'
    'aWqrfLMRg9-Dn5Hq0nvlZnm3GY04lj3mjpQRk1WMgTWVFRNUi-QW1C3KxASLHWhknCfS'
    'Suc83xwAXVrTqHO8es_MTULcNykFCVdo9fcYSACtGvrERhDUTVV-O4yvxo-xIWQ_TRXR'
    'pSU5cvSgmUgFXK0jBJohULhWqP3ckXJzVFKaj-YjxuOBrrWB2WEacIbdJJ6fQtp9UmlC'
    'G-fa8cTbp1CfF08T_WbHE6psmlpoBLufFVfzgnOOn2wkMIO7MvzOMIDCSzbsBAFeSZsc'
    'j9PqBbfHh4FT3aYEx7GVz7QXUeiOldVPKnJK0W1PjbTCXrg1JUYgsXNB3wNib6bcWBTR'
    '7X-mbXL44DWeWOTEumH2YKQXKQrvB7AMa4R_qaEcbEccaEQYLuRzapVyFTBmIVr6mzWu'
    '69_Nakvzf8ZLsRcrLMNEG2B-GL-TOjlp3CHJcV1ImY-IFKxxWIgmWBN776PaLR5xbRjL'
    '1zt4ONgwEhS3jtR0cq1WmnwA9I7ZxCc7xGJBpUTfJjxWDqQksaLjd_zNmBd9VJTZ7rfq'
    'kXDotaY4fAKCLgkMt-koJx9vlaFASPGahQmrz38LzQh83eKtWqwIoeB0fNJT6VNY4Dsj'
    'xIHgjYl02Ij4Y4KmLSWTBLTfiKwBy-4NQJXLRVSlIX2Yxu6M_wi7kxY3d9bc6XOYjX0b'
    'Jddq5EfRqq76oKhVrkFqSloJhMYjW5Sn09gmQk6UNQer_LgUy4nS8AbpNDzEMry7CYTm'
    'zKR10ZIGNriEluOIf8WwhO2e94ngfaBFUV9kEnqNQ1-MIV9zSFapeGWpVJgqCthLdmxS'
    'eLASmxXcFOEVyGO38gVAKUmtpm06eFD4j59LHrY4KjXl-ZeN43J7bQDNDfyIWzdnic2L'
    'aBbv15ovGhuNCklL6UD5K8xJqBRuvjcVSkRyvC8QiAgJrZWhrzzGG3HfjnSXbXAOZtx8'
    'HVB-j9xNUg6zOZj9ci1hmrTvlyRPsnsp4BaWZYmALC2etal_YRICsIavhFTeLm0E1eMM'
    'v6zHrTJhQn-EkYKD9grR2jVNo68AHk7OHMBocDQgO3q9U1lBkMGob_D5JDKpB35ZR3zl'
    '2CkvrMTcW5LDkFBAzvwZEcEm10CZmM6drhXkheW0rZ3jDKFU1NFbTky8ms6Sav_GL0z2'
    'BjS-BcRtu-yUwJFvAjIDP2ZAeK4Bcb2QuqxIO1CjfJnMiZNEb_uVbjxgVbNNDim-7Nad'
    'xL8f56iS8-NFlt4HKIay04itR882IjkO0K9bKP5agQPz9PVMvrQnALyH8fzaQO-4nZpe'
    'dzM4by-l2SUIcpwcmRaTY-LExrESD_U_ZWCISXgP-KQ6xnN7mzZLem84iVDu70v2FL39'
    'Enw1Qolqvr4sCvvuXboYS2RakrikPUUZoPVf0kr77VlvWJtqLmXgHmJyELcn9J_Su8_w'
    'ZqPMf_4Kej67OBcYuVUZFjcuFM7BrW-dAvKWEwYnQWYmfk3jjCvIJ7TGzsm2o94N_9Tf'
    'bOHlNbdIKksgTaMSfM7OZ7NPDUtRncw4jf5nCYm-z4Gaf3-jxQW40W-JcqsKKhIBPfoz'
    'V3czqHST2LkXZfViDkO4aJGEDkIz1A_7QZagXJdl-1qt7QiaRnSVB7Mw_1Qn-mQXwUPe'
    'c6Mbrrevwjt1vJyOnmSqT2luTtemLzP7Y4t8w9gvm-b1b1bDyik7xsh1b3_JPST0D0P5'
    'ezbokbC5XA8m8O_n2EY8SPH0e--vprZdJU0zrp7giRVKH77srFvV739_Vob8fdmyi1iF'
    'QMybFvyDSmoLnQqhIWj5rMftE3ag4VuT6rCxpJqejRcV2tM9SSSSJmBjSbZEUVsfeEyn'
    'KICBkPgsoPwjm2nyd_OKqCdHZa0X0fVN4guEv1oCQs9-PIurXmhixEkjw8Gg4yRroduG'
    'a2aytjyZl5-ynBuqK2FhPRljnpN-L6Dyyfqyx8j5WyxIjbku8fuhrTArip0sg_YjsnmG'
    'kUEImkPtiaj18D10poGvJ0SUmqa3i9r6jTB7Ix2vt7wNk0vqQq-YDV6fd_w0pXm-hOtp'
    'r0ux4suZxAw8OWCzmeCFVUrDgCDxWHS_1hyq7YSoaruHG_EL-doP7ue1xfDvxcsXQBb3'
    '4ng5hwrShoz09z51Lx3ohMdkKOGFpDGv2yFNgnrkOLl4qfoNFl6RH_vugUHUodKg1tsb'
    '1kqOZz6CBcUaKct8row2wiCNFL7vVoXPdHSz0SY_rzzErqhYinKvflpfrMtA_AebwZMt'
    'kkyY1jsIAeUMoWANHQV2IHYNKKHybBOJSdzQA1AStxkSflvSUES2iPWPmBgC3VWH3jzD'
    'EaDv61NCtBUjJofsasLplY2-IxcQhs-GnG8gex_me0vUfr1-loa_aecnZL3DPXYpqnzy'
    '8NaI49XIrZUjO24f5wyMxFTylefDkOvj0TLkA96fpswsl9rMbLN0-qUUYVgMt-PmK9T4'
    'oVn6R88vgBU7oSerhDlK3lCfqqmTEOgrTmyzdPepEo3Q1pPj4EE1uY6uUj2_cSQb_chH'
    'OWQK0OvRN2ZusQbRA5auGN8qiTkPcnUbkujWDBiexxJxvKVaAmoWvHb0WRHgsmq5aNtH'
    'vkOURY4vrWwfs-HL5Abwq1T3x_WCAV3qkTQg_mB2OFORKnwT15UNz9S2NpCyh-dgsUbu'
    'cw-jwiHizW_hbQLz-SnC-yp6TWsh4Em5Vn_a2hJYVSv4n_y-74-bogD6rQVkfa6BxZRA'
    'u-z8-44cuL2CgwgPdo1ftbudq-mXLB5tCUfl56AJz7YXE2WqvFiz9oDetr_W7cpUaFnC'
    'ilY4M3tevKud4nPaTA1VWOSn3oR8mnGM4b_qPCoF7SaGBT9qghTVgWel8cuFL8YyqaV-'
    'MOoD7BEDsZPodXEE3rwiCOEbXHc0wVydCJw2cmSDesmyZcBGWMFKnoNTREHfEMGX9g4_'
    '11xZfqUob2IzvTyvTTl4tXy0TzotbE5xYZ5cNF0hGsMa2IJUCz-8afpAsMfYX3bF3_w2'
    'sHVmNY7rvGW8E02qH8EClMHmQFfJGLtqhi7gxJn2jKkxVloX9pxqrOeWbYlHTQLVHE63'
    'FoYZ17NWuQqdiWanZvDNYk270Aq2hhEFtxYoZQLDe6bz0MQR6UO50UKDjCja0VxGjb1j'
    'lRgCqyJoYzAvxlU3rBga51oGBgsdQeSwZQwhRtaijX86kZZp_CbQeH6Mk34AG-kFukth'
    '1W9O4DcCkkqKircmY-fFgG5oA0YljpHik_8H6Apz4kXVmOrFzvxBa1t0F8LEnOaKlqkb'
    'HhCWOsA9KBfS70dBl2QVODwPYdHIgx_54v8RaMv5Vj7abwbCNnOffQn5EztvZNQ2ecZx'
    'iOoeu5qRnu2BXos6JfSik1V7vT2gzZ2lrjoDFo6VxiUi5SgOGJDI2-8r259__9NakQaI'
    'knsa53eaCJWSuJOLT5Bv1HCdTU3mhIR4dXGdDh9CkosI7NtZm89uT-8IQuuhtroAOMPR'
    'lY6KkhvkXvHyxC6KkQYutQCq7NzvtfwGPbd_HTnswfbIaylXHgICHX7Y91GKGb8vKymO'
    '_em_khfBtm_SnG_FcRbywedfbzY1UyMzd4O2p8-7SOtkSPcDwScB4DD8ovV6RJkbIqt4'
    'Rm9Lh-Ne2etqzJQ76y5IYmEL2HIn_lE9EVPmoEseRUXlPR5OpHsaXNmIYBlLY92MKOxt'
    'PjXkjtX6g2AQjpP7N25j-Bzl2rYsL5NZ6GWkGIqgk1NoGaCErfs37oUHcs-y2nG_hl3j'
    'gmX8mrHfxlJhU8sXnHVQLI8Mkhfsitlfpf4rNf_ecvqSP6STJziN24QlPLkTkyPyIZai'
    'flcm18aPfMFVA7-wa1RA76oqA8RgVdeOrhV4fV2aEBQfaHENN0NsEgTU6DhxPh8G3cNW'
    '5UCsnf26LCVusUBjUAP5tXUBAmMsOlQ5QcH1y77K1JJa-ud8EXLptnztvO1S8Ynh2lke'
    'iJxFuoVkdjGb_NJ0oOFNrVBOg3qzP_z4fdfEDGRCy9CVUCFVGjXXmw6b7LmnZYIiCmES'
    '1T5Q4BjOOVb60U6d5U3vWHpzXc1eaac3TvHR62WLW5FoTcS760r4cetftPjrimPfn0Xp'
    'gOHHnftvuHkszgiFV_shas5EgaeHw9LGoU084mExRzlwo-Ik2_ZPRiWAwr78TVPKTCH8'
    'T9ti5FwuOa_zoe373O99m4SDj-1NiXZY5N5gpZVOkqVZEWvyXKAVwJqghy39qEMULzZT'
    'SUiqkmGtRB1RGqqcwP_kKeF2xXDa0-GI72oLMXCoZ4py1sImDEsHWwA_uYlAv5A5a6lD'
    'xrfsdMaX-FjwqlssyifeBoreXSue4JSaHSpJ1660-GVqPHSjNBr_4ng_xhhbrCCf7HOV'
    'wKeglB9ykSz-MS_QTV-u7ZcwqQZ4hOJtdtljj9RIQE6gSktOnONyWMXYK8DsXYRRTvfa'
    'LMVMBBIcbYdC6KoCl2hBdKRhC_kTwy8bPg3PKyCgLk-iLdG9uLhG5X_Ei4-ZTCWlH7Yj'
    'ssszv0J27s5bKkT-EUkNpMfQ8-HBlJjhdTOxMPf4e7S-4C_3xGeu-YynVQVbdtgxL63M'
    'Pd2UR5soa9MO4EAELQ9Sw2qvWB2YPrsuMXzbsT1tKk5dGwff0UCHoK45M2_NTICBP3w6'
    'JgSoHZRF2B_n9XHru13sP6O2wqtFFAg5nvzVcst6bSgHv5Bds1JHnkPmccXSSudkVPQx'
    'YYaAdj9YE825hdOMGLCU7oorvaX98BFiOPBpSd7GMK57UZLg6jc29J7ZK2_BjIqZ1Fms'
    'ObOUC-FZdUqdQSZoyTPUOonRQiB4eJgZt5QxzmXSNxTHK99O1o-tgvJHe2hgfpsROTLw'
    'TTIdssgi6gmZT6ldV9CmaRUzqMewvAdxMn9XJIRUycrBw11dZaw690lwxlZzJB-rX4oE'
    'ZiNS71wUah2N3hDJb4ytedRS7TpydQgU5XHk2XSl3XBlWDIcMAn0c-A0xV1lYnjpmkaw'
    'vdi7cudgJoDZu_3XssvAyqyfK_F0lUmrffzPQFhI7RJ_omz2aoecsyYSKrUyjuNnxhaj'
    'DIy5VagyAbjm9WxbUEx1UgdBK-uke-I3qnIBjqPspWqyTL2nXzDsEQoarUkaXTySULSA'
    '_2BhC94feijwPEsbmFL6gHDto6BMzY6HFOqWzD9h2vAIBIjxdoW7coJY9Tn8y961Qfgn'
    'K6W_gBbrOVzR2R3egakYsfVpL4rua7MMFOqImP94y5qGyJZlaDltrQDz8ArU3rVPsvgC'
    'ZFeRsEqVsP9_fiSTP8hCNuyNWgzQBxPZGW6Gltle-gWTnJmaojc2mIvvAaNGkQE1S0Cr'
    '2zEmcFE388hugIqZw8P9vrSiZefFKXKnUkkeQk7RhVG4P96yvwNZPOYTmAih5KTJVyV4'
    'BG2o7C2cRpX4ozObqCTHGTuXW2UYJb_Z99fg-2eM-55MumwXKynNxBH1zS0XbrQzOUXn'
    'NFyBqxfzef2dORHqPsWdcyNgQeKCGarsNlh1Rnd4j4sBMRmeg5Bz42h_m5mbUiJEB621'
    'v6RN98B0GTdGs950qCD9aJElz37-KsUzohKrtX_6wsvLai_3IXamb847vX5YoN1qN2i1'
    '94UC2GbzExfMGuROhaprrVuZDn9HWbPtjyQdmjBr9AoD8a7jjDODxUHWL-HN92mXZVg-'
    '3SgY-lisFHEool2QrtuP8nj_qN0Ely1HdIhhVmW7uz8XJmlMoOrY0fEOhUwBeKPaZV0l'
    'fLFZz3qZXh0sjZ4U8JiqFS2KVIdz9QNe2aER5d8K-2xb_GXrM9HI3GVt2l_tIGhvmJhs'
    'YlSa03ALyBBicbrfCkVi2uQDqGtokaUHjANv1fZo3oTJ4Jx2LucWnSkwQ0E60ICI1LS1'
    '-d9cGJjNr9FrF6e-Us0oAszkuC8gaSis2sKJkqUpA6viYuthsSKRRyk3XzRWeFvd_3nY'
    'dg59o-btTZkindBLVlf3_V5vxTtlgWzJEkfA5HrYF9ePP4XsOfnt5MsgToTsLQqZsnn3'
    'ax2tJFk8AdPyo8BS7i9EhU0EKG_1JT-OiKtqXG_bv7xleLugMHk2jFEIDFJl4WpXhb4Y'
    'e_-FOPfe2oBZkES8JfxT6R78pCrdcb3AG6x76bLMRqYoBcHG6H-rJMmi62IcAy7yGqFw'
    'B1YLuMN3-ZxVvM3MEMxvW2F_Dgm_L8NrVcGI9yMvOYLLQfeVGZF5-aaGrv1COgCzZSCm'
    'kAOt6FRoOpPMnsfL8hq2Hxrxws7phnkkfUn2zUD_D96a6e9tUmeYeUiZZ_qmtGJQ5_Qi'
    '2nTCOodih8GJIdPuT5Lkri4jsF5kmfGFUfSNaU2tYd42OHIjWJ3lGj9HRSdxxvipwMC1'
    '6hRorat3YxXFE16EyZg0VjeYcPW-RHfHs4U6oBBocNRn4mb3-vjcxtrJL52HauXEYH19'
    'PxpZ9o7GMUUX7TYbMLfCQ0lnuL3gFzdMVHOImrDDrRwhJl4EHUWPkbUAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAABAoTFBge';

const String _goldenEntrySig =
    'ASJxOLtd2J7Zpzfi2SOhb1q4pRwDWTOVVkdhcRVbauZjJXXPcwPy1hM_ApaOsH0IglRF'
    'tR3ZD7OnpD_pJrzCBDrxuBCjzoq_-VG_BykK8scbrHQwFzW-Jk3DNSNhpkYIbxsdJe8y'
    'k7eZi5TI13Jzcq4sAE5CrIz0S1897Vd38gBhz7HaK7FqvbcTzKox8JNRt8Nul0IDmyyy'
    '2ZyX62-4oPZktZFzULNFV2Ctf4jYt6nSuEF257z5ZKZeNEu7xf1RHGEAOTgEeJopgBF0'
    'oAcLvnhQJ_rNZwXzTu3VXZcxwOlyOEssU03qh-zLsOtSfzjGXBJ_jJR2QF3BtFsxORtE'
    'CfMKr5spephSVXrjt-v4hYeqShD9m5njI78VxJjScIVff2GbC7XlUQVuZmDoxNS3rmWb'
    'fvw-3rS8dwE3CqZtHCZouFogK3AOXGghRldkkTNmhtILNERGDtFMnD5aB3MPk2T7w2qe'
    'C7PQjO9Sftqm-i9KZRvwyNSSjh3TbRpo9Kfx4ts8mCQB7AKx7tV1AYF0SkW8ctm3VncG'
    'N4LMnVIaEJST9FZKJzW1E-Qx_yf5S8oDsy1mDtSCNPjQuAN3O2aSHlyX5Njsm8G5rlZ8'
    'LMVGxMUCkXQRCsMcD-HyKxI5UBuQqXcCJzfQmBi9cMKZcG_9J4cpnT2gRIriZg03P9Em'
    '4WvrcQi1yFwbs8wVpVVYeifSrZmcGc50JN8CVmfee1Mt7n973tyffXOXLfwp5E14s4VW'
    'iq9kjSSOmDzlc6gicseRg3WntJ9iwWmuHpjcOTHnkiZHS7QZnPBhPSxeM2P66EwkzWaT'
    'PYFVdu2sesDul6SEefFvWt3jouXFfrOwDK1NWLDvcQ---uI2mV5-KxR2ybiS1Ql-Qbkp'
    '1ws0ynu4do6dWzAEej5nne8VdCj-LwIQm6Cit9GzhHcDq3CrITh6WJkN3gr9q-TCltG9'
    'KbXNDsbD0Pdwmkkw3gCBCTlNLu16WpfyW4wo-VK50VnG-m1xQSc1DNCs72vidjXI8l_u'
    'OHzLIfAJ6DQmgPm6FifOKBSpJnu1xK75uxAwv3ZvFoz2cjrSLerydppCxqzK72mLqf65'
    'F0Ot-eX4wjeiGa3LzQAre8PQ9Sf11c7hrxzIonxseVJ1VIeUeTvN3rjNoq_MekHMkKu5'
    'XykgP7VrofDr83gTYfsuAQfeIineCRhWAIw4qoljfIl1qCJxopYFS8rv43-zVjxsgxS2'
    'swf-v-LGjzjBdEukkvEvFN5abr3Y_sm1CdEnsZr4MYJjICP9I0oNVzPYHD2Z7YmPYe-H'
    'zYTzk51igVtyTnl7lQoZKupVU9WGdx8jIp1FNLI0OJ4nhBvrzXO64JrGViyQaCrK5ZQ7'
    'mjWFRbqoNu5HoMDaF6j7bLZsCR1aY9XFirdx2vpAdCcMCPSW-eAInAypviTilxmv2l-f'
    'oEKfRiw-CpW-JY5JQOhl-7hYZtHy67GH7Fc4s_cJ4lquxYslEY8g-JorRIuRVEb8f3Wj'
    'eOKihCwZUQ7l1udf0zkl1nDj9610Jn7bHSC1gympyWDl6LEQQz6hrDR070sHJ2b_T5XT'
    'YaNwJe6CR2vOObjCqd_D8LuMV6rzYDkQ70raikPWG45iC5Qn9DzcxwYgVOYUcX2bKtD6'
    'affbpf3o6UBplkuenIrNZLFp9nnkj0Hf1y2rn98kQF4tHd4Eqf23ubVbwK2ZIjp1AIYV'
    'z9a2NqL_6lv1XgNRmCj2kBUcJ8y9AHck5zoiDjzI2R5ndE1AmpM3S9v9KZJFE4GB6XlP'
    'UHLpRktMozqJOaoCiHR0ctFdarQYMyq5zuQ4Xkakwrn4yoKwZ-UKGKM1KrJ-WNDyWIw6'
    'MPUTa_i1fIIU0S-ixwRTUVKAMrWj2zl49iOug4NF-DuuZ_LQMSEdXXc-mTtxML5DkAdh'
    'yXJ8W1RBUDi1eelk952Up8dsZoqQ615NhnhM2B7d3QNOFQN1D3fZrKezQY0nG61oVmB5'
    '4Gp1gQ4JTRUUbsec6ycJezrsaEmdCVCDnLnCi6VbKDR8WIBdHzuCxdEa2BYIU1FSqF89'
    'NTopSfbJiMHSNiFr_1S3DBKcogqx-SI_9uAa5USg-MI-EKXgDwDzbM36P6g7uMedz11x'
    '-dr5SHcHsiP34-Do1aEkdPPJXi91eTzAI2md3HQzwOOFtnxSs_AQYJB-CrWN478FD5e5'
    'Ds6wXd3zS1rveDLPwJj7C7Z3wgAwtKlEn_UtT1VQXxsdalwUqTnRzXe7fiXSFPOXzYst'
    'TmUHqLsY5v6l-8C5NFjaLfqfU78VAIHtkV3K8sc_9BmYUWPg_EF3lZQ336K3IKB0faS_'
    'LLIRp_Qyb-JqiwEI9YhrvN4Yi1zPDzUKZVK2cE78Bsj1Q1NSArp37RAs2Qrim4xAPn1J'
    'F-XRIFn6mSQOPgBeB3OxgHzlwfEtzwurSnqe5p7Hv9JvQ5Q0OKp74cFSmxW4JLe0xIxa'
    'xFKPAFGD9TvyqBvVe6afrG_VbRiUgjS9EFm-IS1A6zcq8KEe0AdFYwr5WIJMhnIvtDGW'
    'VbAChdK0L3xxCPxxIapQWVUfiqea9p66VxSbHixHZNF0v88LBI6bjMM_IS0icjc_YGyq'
    'w2ZsrnLd130eQoYdwZ564XhgaRxutyBrlpfHBZgveMzFlyz9hD3kBCeLBJ48crZHx79v'
    'ijzQDPqvVNkezqH1FTvyRUFAtKtay0FQTtfU2_FfGcYU-cYZ4iw-mZToPada_l1ONhTB'
    'h8q41EPPYVqQ0Mox4L-MaWVt6Uu8PrwuZQN7phxb6zCN-y_pThIsMAZ5EomS-c45Yixu'
    'njSjfGmvzZM9bMluaRg31fhEJ_QsPaVPaEpTDOQLgQeZw0bl5W8hYgbcMIXdwFBl_Ebw'
    '9IOlR7ZlJwyHem1MT2TcgdiVDgimem_6DpU76JbgSpeuByN3cjyTt8OctiW7AO0DpZn-'
    'CLFiG-M6Mbut4POBoFVjbBEnMUW2z_Ruawcs1ueGxUNCgevYRSoWNcCDMAt9NCPEyZSb'
    '96qO3BJligHhlRgWT3enOetfHhAQzqOuHZ2ShNLTiRldw68dmh-aNrqT9dOiS9pVgIYm'
    'EjmqotIDqZzrw9VAk0FGYZxrcuMAljKcYWpDc4Ng5XMBT0-k5iM9oXlGFobs9nyPssFd'
    'cFLo_Zz6OnK8DKXUsz69C-XIBKaGUNY0G8TfsLTUbWIM1fCTV65WLsqbfWrK44FaP85Z'
    'c4063JgwGqbiAWYUGw5-uHUostJQ_VjwYXcqjKNaQGlIwnFnJ6M4kJbByVRyqa8yvqcZ'
    'CpBjKwko-mK1JINp1p2bFKFjwfgzq1y2FUvg7jQNQmTcUWJhrDN4wsE2aTi_9s_4zUx9'
    'qEofHmqvOm-54Y6sYLibblH0GEE4eLQmts0k3g-S5FHrTIqS30vlHXyFnW7Ck8GOq_y9'
    '5CqrSDhci06Oupuvj6mzv9Zvr4VIz35IuGhTnzlHoHN6Bhj_bvZfQ3PRtKantN_u2dtE'
    'dVsAJdlJffx9MYy1XCCzl3yfqDOibV6d5QwMiq5UTuYXePfc2DyxqwDLMk7d_47rFENW'
    'F4gklp2lLAviqQBc_yc2pPKcZDs9ML16_mY48zaasOZv4w0ANUIX9zmTN2Vpo2hCmmaD'
    'fLeyxEr-IoQxv29UU3QCrMOZb_f1Q5aXls6EbXIKObtFJSAEGMF08b9KuxjAlz43_14U'
    '6-GstgZd4cmAQr2vCfG4mFJajs8q98DIKTRrREFX-ErEeK1Cb_3WUQZyZ-heB3zxzNUA'
    'ZLHb5bpQnMdpIX6bdGDQXdkmlZ5cWEAd-qGuAokKqkv62I_G6QUMnYKrfNByiQbRBXX3'
    'hqq8lhkCQVAlfeoe8L48LGgC3mjjkt6Tr2vpheEZbx0H9HDsq2FhVdIPwEd-AIpeWdu8'
    'K0WrGqEa39_UyXGkz5Fm8714uFbHlhsTxN9-JMewm3Pqq3T_SKZ5E60rSFbeBLPU8HPV'
    'r7R0N5bp6pAF5_flkfdUIhBWeCUKYPFaLVT3n2DY1wMU_6yT1ll3mv-g_X6HMMR6_3Ui'
    '0gjo7H5ieDfWj-KE0Ty7u5j80hb8NT0PwF8SIO4vQOq0VKqLMY2gw24xL-m1QzI0wGo2'
    '_3cTtpmEgJjyaFvsNEDPfIfDP-gSG9kclGchO6lAkCdx-zmss77M7CX7BGbGXvKkYd3R'
    'VmCKjpjgBeL41LEcN853O5VLkTUlthKhBGUb79W6Y3p6mQgTmJYTw9L_-er08oxoedtm'
    'sqWfXazWWbDSbFSRmyNNwaPC8AHtC3L2VcK4ZsD41g2T7iklnSdDmr_fgKTGp4_jFN-R'
    'oUgnKLLcNA_jhPzUA96kKaJgrN5rOTfUWuvWt5jXU-tpQmQTIj06VSS8fze8C6oFySlz'
    'o7m0tmth4TjpKNWYgvVr8n75alKmYnA6JnTmjDryGAJ9y36OmaM96gYZVuDLCbnHQOSH'
    'XR-NrehRVFgL0bXOS4JNccvZhn8yJkwZoazsDPwXKjdKivQ_kJWipdTW_CRRdZntBypx'
    'd7_v9PYymMX_FiRcXYug1N7h5vQAAAAAAAAAAAAAAAAABg4TGx8q';

const String _goldenCert =
    '''
{
  "t": "dev_cert",
  "account": "GvxpjbEpHeAspfmVluqnYhFQfp1F26F6-uU_uKvTpxs=",
  "device": "ptH5foYOCqp8G2Dht8FZdVo8jjqp1uF9wiU8tisLjPA=",
  "dpk": "$_goldenDevicePqKey",
  "name": "Telefon",
  "issued": 1790000000000,
  "sig": "$_goldenCertSig"
}
''';

const String _ledgerEntry =
    '''
{
  "v": 1,
  "space": "feed/GvxpjbEpHeAspfmVluqnYhFQfp1F26F6-uU_uKvTpxs=",
  "writer": "0123456789abcdef0123456789abcdef",
  "seq": 1,
  "prev": "",
  "hlc": 117309440000000000,
  "kind": "post",
  "body": {"text": "Golden sample", "aud": "friends"},
  "blobs": [],
  "account": "GvxpjbEpHeAspfmVluqnYhFQfp1F26F6-uU_uKvTpxs=",
  "device": "ptH5foYOCqp8G2Dht8FZdVo8jjqp1uF9wiU8tisLjPA=",
  "sig": "$_goldenEntrySig"
}
''';

const String _ledgerEntryId =
    '9546987d2bd3d0bb5803044f2482e6f56dc53a4717c94a7cbd6e2f02c47b0fb2';

/// The same kind of entry signed with Ed25519 alone (the format before
/// signatures became hybrid): refused.
const String _ledgerEntryEd25519Only = '''
{
  "v": 1,
  "space": "feed/iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=",
  "writer": "0123456789abcdef0123456789abcdef",
  "seq": 1,
  "prev": "",
  "hlc": 117309440000000000,
  "kind": "post",
  "body": {"text": "Golden sample", "aud": "friends"},
  "blobs": [],
  "account": "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=",
  "device": "gTl3Dqh9F19Wo1Rmw0x-zMuNipG07jeiXfYPW4_Js5Q=",
  "cert": {
    "t": "dev_cert",
    "account": "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=",
    "device": "gTl3Dqh9F19Wo1Rmw0x-zMuNipG07jeiXfYPW4_Js5Q=",
    "name": "Telefon",
    "issued": 1790000000000,
    "sig": "RhARaGYP92Ka5HrVg9-ksTTV-w-Gmi9vwQ8JlHEpxKd315IyQvO3tJ6qPQZ3ihHF4bVOhKl4do8tu3eYESApDQ=="
  },
  "sig": "n0wZS3NydFH3Eqs3jV7TeJlAvrvVbGsEPnhlvU2qB9kP-6iIB_WwywtEc0GgPZdqveIyjhH7nWS49kJRxRrdAA=="
}
''';

/// Asking whoever holds a post passed on beyond friends for it.
const String _postWant =
    '{"type":"lg_post_want",'
    '"id":"$_ledgerEntryId",'
    '"a":"GvxpjbEpHeAspfmVluqnYhFQfp1F26F6-uU_uKvTpxs="}';

/// The body of a `post_ann` entry: two notices, the second about a post
/// its author removed.
const String _postAnnounceBody =
    '{"items":['
    '{"p":"$_ledgerEntryId",'
    '"a":"GvxpjbEpHeAspfmVluqnYhFQfp1F26F6-uU_uKvTpxs=",'
    '"t":1790000000000,"r":3,"h":2,"aa":"$_ada","e":1790000600000},'
    '{"p":"0000000000000000000000000000000000000000000000000000000000000000",'
    '"a":"GvxpjbEpHeAspfmVluqnYhFQfp1F26F6-uU_uKvTpxs=",'
    '"t":1790000000000,"r":2,"h":2,"x":1}'
    ']}';

Map<String, dynamic> _frame(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  group('ping / pong', () {
    test('a 1.10.0 ping or pong carries no version, and that is fine', () {
      expect(PeerVersion.fromPayload(_frame(_ping110)), isNull);
      expect(PeerVersion.fromPayload(_frame(_pong110)), isNull);
    });

    test('a ping from 1.11 names its version and capabilities', () {
      final PeerVersion version = PeerVersion.fromPayload(_frame(_ping111))!;
      expect(version.version, '1.11.0');
      expect(version.build, 11);
      expect(version.caps, contains('ledger1'));
      expect(version.hasCap('meet1'), isTrue);
    });

    test('a pong from 1.11 names its version', () {
      final Map<String, dynamic> pong = _frame(_pong111);
      expect(pong['state'], 'background');
      expect(PeerVersion.fromPayload(pong)!.version, '1.11.0');
    });

    test('what this build sends uses the frozen keys', () {
      final Map<String, dynamic> hello = versionHello();
      expect(hello.keys, containsAll(<String>['ver', 'build', 'caps']));
      expect(hello['ver'], kAppVersion);
      expect(hello['build'], kAppBuild);
      final PeerVersion? back = PeerVersion.fromPayload(<String, dynamic>{
        'type': 'ping',
        ...jsonDecode(jsonEncode(hello)) as Map<String, dynamic>,
      });
      expect(back?.version, kAppVersion);
      expect(back?.caps, kZenCaps);
    });
  });

  test('message', () {
    final ZenSignal signal = zenSignalFromTransportPayload(
      sender: _ada,
      payload: _frame(_message),
    )!;
    expect(signal.type, ZenSignalType.message);
    expect(signal.sender, _ada);
    expect(signal.messageId, 'm-golden-1');
    expect(signal.content, 'Cześć, to próbka');
    expect(signal.messageType, ChatMessageType.text);
    expect(signal.sentAtMillis, 1790000000000);
    expect(signal.disappearSeconds, 3600);
  });

  test('group_invite', () {
    final ZenSignal signal = zenSignalFromTransportPayload(
      sender: _ada,
      payload: _frame(_groupInvite),
    )!;
    expect(signal.type, ZenSignalType.groupInvite);
    expect(signal.groupId, 'g-golden');
    expect(signal.groupName, 'Paczka');
    expect(signal.content, 'Wspólne wyjście');
    expect(signal.avatarPreset, 'zen_avatar_2');
    expect(signal.memberAddresses, <String>[_ada, _bob]);
    expect(signal.displayName, 'Ada');
    expect(signal.inviteId, 'inv-golden-1');
  });

  group('posts passed on beyond friends', () {
    test('lg_post_want names the post and its author', () {
      final ({String id, String author})? want = readPostWant(
        _frame(_postWant),
      );
      expect(want?.id, _ledgerEntryId);
      expect(want?.author, 'GvxpjbEpHeAspfmVluqnYhFQfp1F26F6-uU_uKvTpxs=');
      expect(postWantFrame(want!.id, want.author), _frame(_postWant));
    });

    test('a post_ann notice keeps its keys', () {
      final List<PostAnnouncement> items = <PostAnnouncement>[
        for (final Object? item in _frame(_postAnnounceBody)['items'] as List)
          PostAnnouncement.fromJson(item)!,
      ];
      expect(items.first.post, _ledgerEntryId);
      expect(items.first.reach, PostReach.third);
      expect(items.first.hops, 2);
      expect(items.first.authorAddress, _ada);
      expect(items.first.editMillis, 1790000600000);
      expect(items.last.removed, isTrue);
      expect(
        announceBody(items),
        _frame(_postAnnounceBody),
        reason: 'what this build writes is the frozen sample',
      );
    });

    test('lg_post uses the frozen keys', () {
      final Map<String, dynamic> part = <String, dynamic>{'x': 1};
      final Map<String, dynamic> answer = postAnswerFrame(
        _ledgerEntryId,
        'konto',
        entry: part,
        edit: part,
        tombstone: part,
        profile: part,
      );
      expect(answer.keys, <String>[
        'type',
        'id',
        'a',
        'entry',
        'edit',
        'del',
        'prof',
      ]);
      expect(answer['type'], 'lg_post');
    });
  });

  group('ledger entry', () {
    tearDown(() => debugOverrideHybridSigner(null));

    test('parses, keeps its id, and both signatures are hybrid', () async {
      final LogEntry entry = LogEntry.fromJson(jsonDecode(_ledgerEntry))!;
      final DeviceCertificate cert = DeviceCertificate.fromJson(
        jsonDecode(_goldenCert),
      )!;
      expect(entry.id, _ledgerEntryId);
      expect(entry.version, 1);
      expect(entry.kind, 'post');
      expect(entry.body['text'], 'Golden sample');
      // The entry carries one signature and no certificate.
      expect(entry.certificate, isNull);
      expect(entry.signature, hasLength(kHybridSignatureChars));
      expect(cert.signature, hasLength(kKeyedHybridSignatureChars));
      // The device signs naming exactly the ML-DSA key its certificate
      // publishes.
      expect(hybridSignaturePqId(entry.signature), cert.devicePq);
      expect(cert.devicePq, 'OvG4EKPOir_5Ub8HKQryxxusdDAXNb4mTcM1I2GmRgg=');
      // The Ed25519 halves, made by Go, check out with this app's own
      // composition of what both halves sign (the ML-DSA halves need the
      // bridge: hybrid_signature_test.dart).
      expect(
        await verifyHybridEd25519Half(
          unb64(entry.device, length: 32)!,
          hybridDigest(canonicalJsonBytes(entry.unsigned)),
          decodeHybridSignature(entry.signature)!,
        ),
        isTrue,
      );
      expect(
        await verifyHybridEd25519Half(
          unb64(entry.account, length: 32)!,
          hybridDigest(
            canonicalJsonBytes(
              Map<String, dynamic>.from(cert.toJson())..remove('sig'),
            ),
          ),
          decodeHybridSignature(cert.signature)!,
        ),
        isTrue,
      );
    });

    test('a fresh store takes it once it has the certificate', () async {
      debugOverrideHybridSigner(const _GoldenSigner());
      final LedgerStore store = LedgerStore(
        clock: HlcClock(wallClock: () => 1790000000000),
      );
      final IngestResult result = await store.ingestJson(
        jsonDecode(_ledgerEntry),
      );
      expect(result.status, IngestStatus.awaitingCertificate);
      final DeviceCertificate cert = DeviceCertificate.fromJson(
        jsonDecode(_goldenCert),
      )!;
      expect(await store.addCertificate(cert), 1);
      expect(store.entries('feed/${cert.account}'), hasLength(1));
    });

    test('an entry signed with Ed25519 alone is refused', () {
      expect(LogEntry.fromJson(jsonDecode(_ledgerEntryEd25519Only)), isNull);
    });

    test('a newer format version is still kept', () {
      final Map<String, dynamic> newer =
          jsonDecode(_ledgerEntry) as Map<String, dynamic>;
      newer['v'] = 2;
      // Parsed (and stored, passed on); only the signature no longer fits,
      // because `v` is signed - which is what a forged bump must hit.
      expect(LogEntry.fromJson(newer), isNotNull);
    });
  });
}

/// Checks the Ed25519 half of the golden signatures as the bridge would,
/// and the layout of the ML-DSA half; the full ML-DSA check needs the
/// bridge (hybrid_signature_test.dart runs it when one is built).
final class _GoldenSigner implements HybridSigner {
  const _GoldenSigner();

  @override
  Future<HybridPublicKey> publicKeyOf(Uint8List seed) =>
      kStandInHybridSigner.publicKeyOf(seed);

  @override
  Future<Uint8List> signDigest(
    Uint8List seed,
    Uint8List digest, {
    bool withKey = false,
  }) => kStandInHybridSigner.signDigest(seed, digest, withKey: withKey);

  @override
  Future<bool> verifyDigest(
    Uint8List ed,
    Uint8List digest,
    Uint8List signature, {
    Uint8List? pqKey,
  }) async =>
      hybridVerificationKey(signature, pqKey) != null &&
      await verifyHybridEd25519Half(ed, digest, signature);
}
