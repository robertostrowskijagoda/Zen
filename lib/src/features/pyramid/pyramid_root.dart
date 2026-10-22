import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';

/// The genesis record of the original pyramid, pinned in the app: its id
/// (the hash of its signed content) is the pyramid's id, so no other
/// pyramid can pass for it. Phones keep and pass on only its records.
///
/// Made once with `dart run tool/zen_pyramid.dart genesis` (it also made
/// the first power key, kept by the founder). It never changes: another
/// genesis would be another pyramid.
const String kZenPyramidGenesis =
    '{"b":{"t":"genesis","at":1792693735335,"by":["qWQ7R3L0DoTBiE00ZDUpeQMlar'
    'bwtImZZENQZ01oxfQ="],'
    '"name":"Zen",'
    '"pk":"qWQ7R3L0DoTBiE00ZDUpeQMlarbwtImZZENQZ01oxfQ=","pq":"WGXXyDSaDvQpxh'
    'AGlSvubZUcUu0cYr4um7cUl8Uzp5E="},'
    '"s":{"qWQ7R3L0DoTBiE00ZDUpeQMlarbwtImZZENQZ01oxfQ=":"'
    'RTEFcdowmodCHrXuCqPCC_P9kIC_jQn_KwyofEP_YLnXLLGMfWec74s19vsktIV8BAXG34'
    'EBF-CeGZJSztYkDrE4XjcywCpDa2FfmUq7EJnmVt8SlW9GQIu4yvkqpa4tte7dIZFMJHLk'
    'GMEUJrJ73B-vxd7ekmN0qf-kJltzBj1yuOA6DrhnUfE_6KemyDHi12yMRaSWavpywqacE-'
    'UlcV9jsJuS3Jiv1fNqnRTjmVSl8pZ1oddztVBXVGwUIYxydXTdLrb0u-MXuFQyccoDiCoL'
    'K44H7X00iO-NR2GeZ2eyMGUbHU-i8k8ONQLXL1Kjm1rdIApYv-xy45DxuhLM2epmIIfHx7'
    'nzqkA8iWlSNAk7pJDOddypv7vaxlOI9BdcdQerEmop3bZUNu8siQbzddIxPrPmqSoUz89r'
    'InOorVNnOxhK79x5j0EMeZmPLnQBQ2-5FOu9pTuLpvBbp6UaQ4QxGMFJuL5cvaQKGAfMA7'
    'MiDBpQ_6R60300Ob3AYZIFnR2yOutm6Ne8S4xg6mMdgx2NWqv62I9q-7Uwvo-bG0USnFW5'
    'IFT6WtRF9vLur7O7aVMpNwjwpKq7_zg35Zyo81v-7jUOm33iMmHfwlPtPIRzCuptE4p5kE'
    '_LCUbk3V7Tk4b9UvwCmRJKxM8Uwi39YDfcO2e1uziojAtHLixQ7lgSmVL6M7XdBB930Y7o'
    'oEn-d_x2It5XrGoUUSfYgg2VGGEuw3WHx9j3mgLiVG9KC-Q82Ac3tsb8l6zeCqlKtGNp8Y'
    'emFWdRcrS4GYVjyXH5wASvbMxGwHIuvbkiJlRp99h7gyq_deIWLlPynyfF43i80gmOj3vR'
    'CdPzKb8CkIuuWfPgTnwce3XPZsiNvo4RGZQhyNo0TOtahGkPQKt7N2qdQLlhMe0D-XeypR'
    'tKL2as8FMfNY8FDS7qO8ZWKUswEtxbTmiBjTMjT9Piil_3Oze2KvBwGzJEAAABkhAPxC5Z'
    'lGES3rwOXWKmZElpmm0Q8lMpswF8RGbM04j6N-Z5DntOomF1iNLdVlM4Lohz2W-FyzKmOo'
    'SBZzycql_nAcJZQwmgLPF7oXSn3P2ZypIrpJH6m5TcXyyOG1zTjK1hzO16kc-Gl3HTmX9j'
    'tZrj76jv1AWTu3fGCVV5CfZBV2TusL417fj-WhN0L47P-vA-5slcbuQtgO9xe7tUFHD7Q7'
    'Etw8_zsd438sQYkQ-v6N_X1_HRHUKmBXsX3SF220wDDdYh8G35B7K11fbOpzE4MmR3JKna'
    'qb-ExuKhaeiDP_q7zronWH7gAug9Cq5nxmBuFqfh3P4Vn82wNNz3kF402QS2P-oeQUqdy5'
    'C3vdHOMUOs7GhSdB6Hnecd5vOZVr46aAd_AdFlo64SYDTzgOuwmU_pJG1ElBvNRLm0-Bwb'
    'z0yRpxZJFekx2rURdFVoKoGqCOoZv0zowYPvIOQjnBkU_XQyngoJW3cNY6n4uxdq7F6-Ud'
    'IX4OTT4bndBXx8-lyxDAcPOgwnXPr4XOgdSmwb_YI8b8WtD773Jj2aAGSIRL6h0-tuQ88Q'
    'zetRFxKxQm8BLVmkWXx1gWfSiVEqSDNTcjcvtao50D_nTHyiog4MhlNvmhTTXJ0x3Z_55J'
    'NxwH5bmDIQ_NpIvWh46aF9Q4-LwdSVpGsenJN35taD6m4_l0tz59It0sQ2QVjMfUzgMCWg'
    '4aMBEB6NWvTjoAyQ-b-jKv92L2jXtHZjpqpC-zBR0R30vr-KQirPAAq7qmCgy3XM3l9T1V'
    'Ckg8VGqVYQtpzAHM_fRloJGwIYxdV4CS3yrHyyPPsf7_LrzEt7oVD5ZNbODtClcc1Xjcju'
    'pa-JBXRHQ16PR3w8qbhhTaWkogXwQkgXStKlTX8yQVNd0Q4VsK1BjPV1Cpx30NGMs_DGYw'
    'KRy8b8WU_1jjRLNkmtOzEn6kVo-5SJ1oTvbyBRuT5UHCGh8YS8BS1WCgDOvB7H2o2AG2bE'
    'S6Lrq7zc7Mj244spEOuKOwCDee1EJGwRR5BQReTcWYS6Z4inFQmq594jyBF2b5avd2gHgZ'
    'lJm1_b9n3Oaum-z9hFxHDxGBhIF8rCiORG8YwotYzRh5K1iZvHGp6JfFG0kOv2EO5_ukeJ'
    'Up_0CEUxZ1JCq0sJ6ZcSJyZRSMM0b6TJv22hY6Kq1nNAr0BtOrNRVnDpYRjjmxhtvIJ9kr'
    'DX_89_-xbiSW-Vgcodr-Nd1-2fLofr8l90R1bdbIK2_i0uS9BVKAZI_fSxNF2eYUrEbEiI'
    'QYRG3utG4H10Unb-25wApALJWSkODEr4IV2Py8IuGif2vdxKpi2DetU_pVceyKt-giUTES'
    'cDhOwxEzOR1czau96h3xTA22lvQREHLUdExZL6M-ERhHwz3Vc4DDYI7VHKmir9AIbf2u5w'
    '6nKucWXxuTVbLXV6yaP-qKuO2dBgauPctww04XSqzP-cShGCaH4zqHvf2uFEQowjq0KQj9'
    'PWNEgqik6pBVLj7P8GM_oSoTP8b2VNpSI6qHz-7WK5sABW2I8P3f1ocXb7U1xDEA9oIioX'
    '_dj7p4HFyDJqqzblLJl411TeOaeWQm5W5jgfEzOZLJ-nwj09ihmwabM_msZowfGu8npoFt'
    'LGCZ87rjJOmvE_JHLyfT4rXEq4WeKojdAY5edtdLfTtLDbyZ8KqD7ru1uCyYDLNP1CYKet'
    'uCP1sIxhjgnn2kjQuX78D7Iuwc_jRTL-S6MweVh2OUt0m7OgJ5k4wEubfkwzQLVA2DPzZI'
    'XEHflcwZhXBGQkJOtobmOcKDLiFanGJwFVu1pWg5qnnM-GKDxiuOJfwo5v7A3lJQtkxtDA'
    'WQpY-pAF_9-oh7-tRxszTX81Q6xkio7mxYpiAakiYC2q1c5PvvtWSN3XdgORoVkrZE5xoy'
    'XRsP1yRmYTSGhD5wLAnaSvSU6pbf4nvjjDBqoPqVa3OJHEBHoXGi2jdGC-lC9dfwUr2vCE'
    'MnAqSWh7wAlI1ZEneh0luiI5ohmAazWXJLyk0b4z3BNNHQSkag42rJsK8yruMVj0ZvGOLr'
    'iDgi45XgoaeXZIvfS5OoZ0MArSUd7CEDFigruClhfpnxB7F2LRJy281-MsJ7uV7owB0Ss4'
    'rqqVAJh1es5pvqVPerEcY3lZ1Rvz1ojv6f4k5RF8E49LyM_mh1rri3DgHtYgYJBpdOtO-t'
    'pxLLKzwcQL_KeFRvELQ6ESsWjMnZi3p8vc8rTX2SRUHefm-im_MXpH-IH126_ZNKs8joT1'
    'Sk6FWnacvCEN5Va9LK9CLkW3UVeiLWUxs4Rh24511S3XkfVPR5BsKFQaj0Vn3PowM6eKsN'
    '89Lg_3xC9tC5GlH4m4pr3prLkiHLsKsloSdRsHPwy3pWrMv_lkgwHm_WJ082aZOKCr4gu7'
    'nYAWUHhYTonW2IYe4HB2x5tAewZOJUKxlxfSVns2CEVCnRIbObvnRbTa54rVR0hIu1XODE'
    'VEPk_LKDyRAewR_RWwTnqc4FaZJrv8GBgfRYPqd6kYousmesZnAWKAW08cA66Y6fqQq_zb'
    'ejxeTMgVGeSoCRq6PERFxp7cY1eRQ_QzHRLtWX2x0vGH0D_N1YXFhlYpZjmY291PjWvRw2'
    '6z9rw7bJx8a7s9jqEWJDdrff4c0yR38YtSYblHjiD-yfnJHSG58KD4GC8UFIziFoCGfDIb'
    'tEDVKKh6M82xwYftIfDOD3YMHUDhKfKR2eRWmwwiBcdvIyVbOyUZEGcZXA-sGN8nM8StHH'
    'El94f2Xnyu6eYXxvjcq8TwBt_vUVWLk6rsTrCP-Pwsbnthm4DntymoILfQC_PwET0BdKss'
    'Rjb748JE5FVkpXS2S1mzRqG59Ggemls7PQG1dmD5xUd428klq3iT8T25N0VIj8d4uPGUWm'
    'uepkLyOKY2SN9yLbfrNYPBKVtsFOZXnj-NIljcIOM5S8ZOhoOg499Lw5cW_usGPYJVvLEq'
    'UUSKhHQh1kw2GAPmeCL4RWfICc_TtyrjQbTxu9Sov76lmyFUwuHTQ3qINVbRsCU7bVBeSi'
    'jbeqgHRGbnANbrRBia3upmDa00RVAeoV5__J3XKU73ySAuyqRJoWQ3c1M_6kfr38xj0UV2'
    '6bN_Cj688yLQFNY-ErE2_UxdqxzgMrjcG6xIuWynqoDgnp-J9yoUoKYcMuUVHsSPHt73vQ'
    'pd1guLxGEogtpH2APAZ5y4bn32cL_LinFZWbsq3gYHz2EqiMhZdAW6vxPChDMLZyeA_UeE'
    'sL65GkmsPEzFyCjLNHjYE225VuA5S_vfwnvdPwcKCMBXnNTVN__fjupx7MPDf8lu3TOZBb'
    'qOnkmpYxU_BdsHBf5oI0oI2gRVHEtpRdcSmV8b7XmCrJnc1u90ANWAoPp210J8w2AivmLi'
    '2C2nsvbtvKVEV0lfroicPAW9DxWdCwenTUC2vZW374JSrSSy1FW29TkhnBMHgNZ4tSLbtW'
    'F8FD5i-b594UCircOv41J_BrkdfR3bbp7LtXi_ehZ3HzIb2OrYm5lyTOkPDHAYny-ljWHn'
    'MtYNYeiXMwnyhvmbykbCdf04-xiJbvA4aERawS0CTVnOAgLq5FGDTNIXvkTRHNRpCrcrbp'
    'cnK0oKeTgycJhkQ4xXJlsnAxLS6sKUI1IUPZQrpCB1jRzoR4dj7v_KVvBRk2pyuuiOUWVu'
    '7nFtQLBZky5lPMKcWp05tXdbTLdo7RVsD1aUJeZKE1SvKIWjx8TsAdUZaGP3y_pOr7HBx9'
    'pH51qSJWqPhXtXz7bp38xO_73jf9kkDXafwXK7lrJr0t2U3hLzx1RKUwzItNomKXUKRKmq'
    'PEUZRwTA9G348KYPHX1NwujLPA02FeIg5fcqMou4fz4pV-Vp_JHp1uBeW5hTM5-zAq5FVq'
    'AlFFn8AVmiqRQpODzkDO7_Ne8GvJuCC-dMcCj0Wlfurmd-efpY8WfaLiTtYTt3E-Rfab0o'
    'jIVhBoPF_Y6NBNr7C1_DykF_0pHerjmRXxUWSF4DzatuJYGowYTGwAXAnUrbGBhkYsQtn0'
    '7UqlSgEpLx5PTAUuyy0BEmR57W4BF_1gyhSjrIf1AP9B2YqQSfkY0JVzYjNx4UK4yRU2v_'
    'PdHmU2CU2GxavpwTOozDUDNxAU3Z4cNC7-rq5m37f7b-AUdCSAvhaX_ExWj9Me3A7hpZOI'
    '3-OExUmMS1ubHAf0MgL5AieswOH2JKiznH8b6llyuZfXEJFq6bDtB-Nwvfb141S4fTdS4i'
    'ib6vU95LniX4JDJhNXVFcy0pxnFs-i5yBMxKOYOFJmR8ItA0iiEZGRKwi5soC6o9RNaOTF'
    'Beof50kFA8IMoxGwEfWlUPO3koiKLQWn3A5tPKsoKoH7eE-5_rs4fWcCmaQGloQCy58mud'
    '7rRxsvEPiWFsHjR3o9Hc5Sf7C-y_oNvJWI0nhM9oEe_NLsZFwtdGCu9RjqFzUiFNVamo4X'
    'vdvG-pHyqbSakaUSGOyfl7yzDM49xyCGS6QNApW4CXo5BGF8Y0pFiiw082TxSh13WBaWrP'
    'TYqPA6V80sEC2VsFtK-Ujk69Z7qDsOpl7NlCahyZDaJEFt-LhJem9W6GL9lo8h1xjyxNtv'
    'IbyP8YJAZlau0EtCYnFadJQ64xJdTI3tha6gtlFPE4ZPJLfHqX4MHuO_Tw9ArVU2zQdA8l'
    'u4SpyaZ1Qa2VlMKkFruR2O2fmlsn8ARY8ym2Yuaw5jVHXpr80E5qcRzZFnZiU31ZsVyJOm'
    '1pvmW4ZsQcJ2cPDVwfqSfTOFyh8SEs0Qgzhug4UwhVJc8IPSZ99bFhx0ouCjqpoz4XOv4r'
    'T6GqvoZ_C6dacFX7rprceKWOdzkw-Ihl80UAtQqxW1tnYZ5PVMwFusQwsZLGQfSJoFyhiY'
    'beRaAN7EvqwTZ9uYAyIRywiDy2ZQW5QQsVP1BO1WOsSryV-EigcUi1xBGrdlqyIXDlSt2X'
    't-DiBrJlWAawOEdzE8MRcGqy3jFbzkzCxnT8314qv8PWK96-MZLGayRHEq884ZkZbrnm2N'
    'RvamA5og7HTN8JIihfUGhFj6dooAw9EDkw0q1_FJvVZGYEmDMKazzmY9wGmII5nxkj557C'
    'Z-B2JHOsiuni-jhcpeuDhumqruAV3EQvSP4VYxHFLF0r7jTluqAPji5nLrQrr_DsVOLzIp'
    '4fINIgSHy8V3JYmVO2W01YbJfIenRfIPqXvM7NzR_1Oj3d6xuyJGO9DzzA9XDriQTD_3Fm'
    'ictnAWMHyeDmCmx1lkbF6WaHp3XlnuKCczrPIFxm3pBlKYAxkFl8LV9HytwsyNVVs-2_32'
    'x4Rd93V1qYyXary6_9CkGt25-AwUSZ6_dwpnuN_w_9VsSncwHZt2koCe-NKNpMFHoFfD4P'
    'YvkOeNFEwjiINWhfJpDbooboe9jJiEXaNbnfMju18l4wG9980Y7KbBZNck3NWEP6B4WpaQ'
    'j-jydOV-W_zymca_UqIsDODOAbEbnjXVi1lxlbzQWEPL2rv71O50kLXFqdIb2lRQf6uc7j'
    '2Dy821ubI2N1Je4bFaERiFvcwWeNZ0NCSCUvaJTvEX8tqJuJ9HbanIaKetlBQ3Ugqu1W8B'
    'alIxAMiZA1YCMvEKLxjdYzRGsNOjmhM1-QtmhCkwaR9cCTUdfLv0MeT5fmVZZJKMLDUrfb'
    'elMvDKTWbDSWx2HAgxalMbI58C3MrkyvkfkRLb8KGg5b4BO92hzu-jeNW0BoOCWdkJhKpy'
    'mFeodGkFXLz7EW6f0O-4C0MB89JJhnltMKxnuRt2Cd1J0TV-NKo3ovlp7Xm1wPc1iwwkyV'
    'w82X7GWjliAuMwFOCHI2fR2i1gFdsIU37fKX5vARA_rSU5cccnv9c8s8_PGiVmKpgwzKmg'
    'dC8cvp8pNgpclp3pRSziZmGUrX0RqzgieUtBRbIxjx46hsj5eIdJQ2TXZXEP0n4p1RGQ1m'
    'QTBzyW6zXa9fXX6g0w3_Qyc36-XZskWnfuJJRGaCKfwmkH98q_8mC0f5YgmgntujigG4sW'
    'Ui9oiksjRRwNALUZuy1XclN7uE4cMLUyyk4lhPRjON8UE8BIKLbuIAknML6egw3m7Gy3HW'
    'SjYpF8Xf0JkiPwIMOlFLg7jvFSJfaXqotB8gRmOMlb7xGS07P01bXZKbrsrs8AULSqWvxP'
    'MJNHeLqgAAAAAAAAAAAAAABAsTICcs"}}';

/// The genesis of the test pyramid (tests, and the simulator and debug
/// builds with `--dart-define=ZEN_PYRAMID_TEST=true`). A release build
/// never uses it.
/// `dart run tool/zen_pyramid.dart test-pin` prints it again.
const String kZenTestPyramidGenesis =
    '{"b":{"at":1600000000000,"by":["fqYYVc7Xq7McGfJVv19kLU9HelAXejJ8bQBcT73kFO8="],'
    '"name":"Zen (test)","pk":"fqYYVc7Xq7McGfJVv19kLU9HelAXejJ8bQBcT73kFO8=",'
    '"t":"genesis"},"s":{"fqYYVc7Xq7McGfJVv19kLU9HelAXejJ8bQBcT73kFO8=":'
    '"DVHLc1StWVLGpC-aggp0se31zRo7e5rV7vn-TjQyOOW1wEOdOP_MwJpv9XeAuPcbbAFk5'
    'IRml-J_C87-p7OFDGvMmBLwfduA4u1ofDCCKifwcJPaMAKVA1y1eyWF8fjVdvJXf1ZbzM3'
    'GjwxPoyRDJpqlNH_GNY--CgnhyzNaGlcmIOQXpBqXVYZWhhctEraZB-H_bp7D9Y5zDUuHu'
    'DI-8V-gAg3c_OHHDxx7uAfcwprsBClFDrYmHC-AmAhDpzevBB_0c1AWOgfPG81jbBnQkxV'
    'PQVT6ktvDGRJSw70nI6Gs7VXPPsUSqIeEKqSzqDT0ggXEr7pPC6TrqJNhMPcq4iSgIEigl'
    'W2GsALrkvknIww4qTCzegl7X3Jy0aiPqSXHXnS43HxnpB1tfv1l_A0wTRB-zyu29v31rPf'
    'uNuw7IoURsOZ01-PgT567QHWw-sGto8BuaGQ0oQRTjW65igEfqKAUAYGfqId2YYQ-G2cfy'
    'GzzVcGgqEBLcaGgc4XsGVXigIARS2vQt2a2YeWovMq-YgCDX87Ll9bMBzljypxWvT_rTZz'
    'm8SwKMfh54hDqGMWxJbwmAkdOntxizVwn2EN2YcfCBlGe67vfPmPgl02nnzZK9ovbBMLoj'
    'l1wVk8SgTpolxhimpc13ejrfem2zZrVVmEOoqRZYRsA2INyrhthCT1u6SmblO6Adm6zTYV'
    '-FWEqx9_xHwinCWLlraU-T7rSqFIYzDBQmndn--WOSmcz3Ym_aNFN7W2cMXNBRDPYr5fVE'
    'LgS6LY7gqUsLFyRuQlZB4E2OJU9F_N52UZm-qGjXKhR5AbMW_hKYzJFklQeyDY_PHa2zlt'
    '1Br-ejUiWuvLhEfCmHnmSyC3Qde78pRnjw8cDVLCaAwJRw1cRx3CCGq7MekzqyryywqNYo'
    'Va_ivOYBs7wCUJIYLy8GiL_QD6d1EZKkPy5FBydugRkqCYcKgA04QtA35QOfiRCSp0OKzN'
    'vcb6fcTPCqsWSnkI5TPzEzofQo_9RliJ47hZfiR88bv2m_x2RVzoeiSt9PxsmlswgEE39N'
    'ku589lQW_1AMI8TtT8SMVzwmbeUQN_kB0qADQY4BZypWdONXPt4yXllJwLphaVPKitzhHJ'
    'mhguJN-gtwyRjySWEdiQBlJ9n4amsTsikf3VknIrgVwojRJUC5wLnXdn7MXlwAixcZhY8-'
    '7C9EvGgKKt0KV_cKaaRi6QEst-suDNsP5ht6wFi82uTZ-7pRbKnkLWg28iCClWwVqcLTVr'
    'ouMOjynUx3ZHHhMmMhmqs2mqCUUIzsraFvP4mILRxXlzBwS9-piDeHTS5XiHB4eXx9NJSi'
    'fX0vvSZQ2NHVhTwRqqG9WL7WyDE7el24AV6bjOiusE8Ag0U2B_8UxNFMrT4fM5fmyuVqFF'
    '3GxPxdJ6KGQ9-PBmcd9l4B80D1gghhEmZVVEeK5MSpL5FUWAOkA-NxtePb2c8PsIGi_OYM'
    'W8aeqsdPWEhDoa8w0k7palJK2yG7HQ5pp-UMAycVuj46el_1kDYHJS4ouCKjHHSJbZKHb9'
    'ChI4a5ZS-MkopfKicdrMcuuGdNWKQA-JRizXfJBFGkpcmbTiJfLhig0Xjv6A2GWchItdwL'
    'Jsdx3d7H5XTR3bUoJ2dBrsz3e_X2zv9te4qfzV61DPXEHeTocawt-b72hWs8FlKVoJi7IR'
    'LOn1xHr1nQR8274nZ52LGix28-gnW6JCkpLIMI1IUnyRPbKlM52-DCPQumKsEatnbAT2Fk'
    '-bLl5kLO3yhFAqJvh9StfZetrUVpbA_nrnNVIrAlbF7ePd11NZXF73am1nnBZlBLW_tTAh'
    'BSVDUVe6ssSW_4qG65GoKUmjrhn61HClstYp11G-DifvhumEHuhTph7SQB01HktIqjcYdP'
    'vtAkRt-AFWTAlSTMdiZRgiVfHyxuwnymSMrBpji1kNefzTysZs1tg-XuYp1zv5LkzMSV5A'
    'Cq_a-e-xDNaWe4HNOpQ1BwnkfUCaB7TAb6mjJOdJiL7PxL6QCSSdnV7xQEbRnZcEbc3uSd'
    '7GpfNaqkc76fgV7ybxKVu4ESxoMfKunJ3LaiALKklVNuAg2XBay8DUhzWBWfpFVe1iyuC_'
    'jAuwCY-AlYQtquSz99sZD3aFAGWC1QiigE8c9z9V8ARQlNOTOU-WFKPkpBmlbx-yRzxaLF'
    'Mrli6aYqtLcTTCNfe5yjuGxHNgrRaXuZyQAH6xGmnu_rlphBa0wjKjx9UWsr3B_U6Vtg_D'
    'bjM8YqdXVtkDIFfcqFzyDSCp_7swkXnew5L6mEn6s3B0_UTN-2JDkzGoWN7lYr09Q_DQas'
    'bCUQ4xQWgH-ZZv1m3eEpjSD-dcu6Afo46ZN_o1ccYemyl_LgdFAIhL_xVckRH5rX_aE25H'
    'ECuy12FNG8TDJYh6fykClT60QnFQL9EWeA-O5-QPOLirk4l8rbsBscBQg3LGjO5meBAE_5'
    'qia6Qr_ZK3WQF_yKRvUNgBSgkQpMa_EiOs2qORN_Jd47OyEGDj9ocYqIvwTdvx4ThjyijE'
    '_hGdgFbO2rmWt40ERIMuIp1Z8cZAweQak34dsUKlCzXKf98tSXyq5E5BlfLBpa9_0Db6go'
    '4k-K-4QEPPWDwxeVbmc2GqA1ZJnx3cMSmkB71IPqMQ5R6ZFnzlY19Xce7Roi85x2UJ6Ttz'
    'XDIfo8TrWovyegnLL0tz9Kz18095oRE5f80HCUyKtbh4yFGOboseZXTF866ymUwTSSTX7o'
    'S9Oi5u12KCJZeybqFhJ4_AwmrLDoP65UwtNlV8vzVNacTve36oEhjpml8yDejqgfE6LVrf'
    'ndch5-qDX0sQEZhWbKYxbblDP235eqfvXCPRiWhPsF3mMV7AR9JoNdFPJ0yImK9zi9PeA3'
    '2S_vnlSZlXYcNtD6jvYqL9SC5W41HYNHqYH7454ksVh2lcnKx-qSPj1g6jcTxD2FnSYKAO'
    'r85yDKiBkD6lPQRRF4RScZm1918VEVz6FxXjEBvzivowBchmLQe-OteDKiHUsfFXNzcOVP'
    'N-g9n4o52Fvdps57AIbGcf2RQHFFkX6pO1DPjb8Mn5LhJIh3BgoftsdQfeNADAes4am4sr'
    'iI6jDPKp_yeEQT6ymVcxApF9q6DKx44EAPyo4UZ-iAtn3e-p383NtBiRjqmMziLsQrLHlz'
    'q5QBG6QHMJvWSLUGm9bbuL05d7oWezSijgYX1WhB0ZWHhnsQ_p6IN3hvDCPZSzFHbZk39f'
    '5LvOWdXQHfPq2yQo2CqL5gXfZLjAT3xWCK9OWfeGs7oJ0mG6ZfLNQ6edvJRqt52GCLadC_'
    'TiI_Pyg5JMVyyCVqZoG15bpLeFP3yjn4ycFyL9bc_AtiNWNnHmBbD1yAzL_DOumOyZOW79'
    'VL8pRzA7pjn0KVVhmii-bK5iSRTnLdYpaoOzADQ2O5qZeLVEaijk3pb8EkSILBnGM9aJYk'
    'fJU8mpAytsIxWaMF9ERMkeIEpCJxBVsRbc8xrV0eWOWWzMZo1zki0CVmJImhRX3Snui0yr'
    'Hr7T0zAy56wNpmHhG8HqWnZjOBavTyJhE0ZYfsS12WEz-Vh44Gp7TrJD0ws1C8GGoO3QoU'
    'Nhtbni0kp3iedE1F4Z49EKP9o4jJM0ON2RMpuOSSTkEQrpRVzItOGaQMYsjrRJ5eqiVe56'
    'vXHLXjzYKZFYds-33oPlJ0YNgGJuffUNNgk2CkTA9PRPql_AmJUBweIZCqchqE8A2c9RGF'
    'K1K4KajlIkxvLpiL6Kp9V1ea9PlUoBHkCtCYZWDeimQ5jNVI0qAth1ERssT-tKM2tllNCb'
    'eBL0-kQxXhpz_L2jGp8USpFxVTgVf0LBTpVfIxL3XvaESF6X5mCPW_1p9hevdnToJcwdM9'
    '1EpwGw2bKC-l-cJBKEL2Nnm5XhbdeKClFxdwR4bS_AjKWk8UV5-nGCZVMtNKCJKV4DXKeB'
    'CSpWSK6lJ-VqIYWQRn_I523gEvNGokUT5uyI-oqy0UiKY8X5HzV05C8SDpErpfHHPUHKmk'
    'yMGipKZ3lg3wcG0a8AhI2h43JfVjd7sJtuWkbwL3BfDi_Ws8cac32L4xy7jo08wuz-1vlb'
    'qtK1EjPKpYvI7jMEi1P_d6urNeh_CB19F_7ljWbYfwIM2-FuTeH7gVSkEUuoFzOZMata7_'
    '5Od_AeMJG1WEjixCMBeai21S1W1zdoIfmL9jnJo5ekQyGXlOZ1S7gZGPL2VgTU0gjeDNuV'
    '8Z1EW5-C-zCrLE5NVYNiYAnqV3Qw2I2kMf4vSlFLrHwAGBvh_v803DMD6qH5SXoBECx1N8'
    'I3HdyQFzp5b4ParD_RqqPtsy2PFPXvFCnQ_hkGO5d2ZU_lbvDiMNQspi7rCtlhFojQxAad'
    'KUsYwJQT-dsg_GzYMb2-b8vDFZk-LTMCTF8FJJWZgyJSpVVf3v0tBdr1V_mNFbbgUn3HiJ'
    'YFRGJXS8xcVYApDCoL_OF5qxpRKKhrXZohrBeIjryREy2x83A_1nVZC5I3ASjnr2S2wF4C'
    'F7yHpylzeYDJ7tjsiAIQ7d0GP2ilLpXIbZDRweePSwWAXYpc4MmUsg1h2o-Rf1LSjo5c9w'
    '1QIi91pOnX9H3idtyJmPI7PUt1456XtZnjXsqJsom66jIBPrd7b9SnQym1Hnh_XDXsBvpO'
    '8p6MJV4dqmcrFJgPy-ZGO9VQVYAcXX8-lD1fFwl9L_JI-7w9UTbkcHy1VUal3Xsr-H6mWa'
    'yL7HWKIXjPUzEFxMYrD02SbQJgneClDLxKgzLVpPO6-VebtpQ6grqTcFZaxiu435uhBCiw'
    'HVu_-wPIJi1T2IQlaVKDohVOH4SAHoAHfJdMDDBDxq6jyP8n8MmsLLeyvBP0Q-pZxRmS47'
    'Bakv8Sv_fEItKb_9MmxZt0oTHamst6VFQKBhmvDhPwUZJyMGtrdH0hIW3Stf5C1KH8l0r7'
    'KHJfe6saY1yznD0bytcCOuuAxEQb-cmlqONG3kzaP8HqSivZeU0nM1TG1lHhu8NFCHgDFK'
    'Ng8oOZ83m_XEWkn_JmxjhEA9_-qzOGC7mmLWMC1MC2Et9LkP52qCO2broAtg7OsSPfKN4F'
    'n6_8gpzP5mRYG-SbbmNIxH9yOGtP3XIisxsAkkEExHKaeP8olBQAPb2K2vkybM9s7UwvmC'
    'DM2AqNcF7g0syjYWyGNfws1DsCGd-hJd0x3rC-y9h9SgjViPR-X6-8WF6LG-e5R6R2mTUh'
    'yQH5sZnH661g_79BAFIuOQ352hTQ0ZIHm7Cv3mR2zs7cuevCSq1WDGhyzQcUbjtyU82Ri-'
    'bk-4Vjl1UCan6BAK_l3R0Q8kADD_2WbeFkFfsoO8bNP2jopI795G5aGUK6EBWQHi2Wbcuu'
    '8q8i7630hnCph9Ny4sIgHmBMTqa1hHOxi6SSscIs9t4XBtzVnHn4Abrgklu68F6g0jgnlB'
    'zajS_ljvw92yiGNQfFXOR30vv7oqYPagpCXvDYAK4-Ay9kMV9s8J_XkcbG2xlrGei9MGWU'
    'MTEzTthpUYiXYcDPdDRE1kZKZ_espWm5kHLuyQeNNyDak4zJ355VbBT1pH_FoSt21jp0xM'
    'blnvyvOBUXRbMhYALKCRVxUv1VQ3Snf69kmJWYV3ZJqF9EkZm1DrYDl-QhYgpuSmIgjusY'
    'wABn7rNitysEXnOGU-DXGF-0MZprkSWhoBbs4lQEV6xAbd9zJg0caIq_pv0K5nDPLGnE2I'
    'BId4O5LNmIgL0j22l3sgvs3PKwaE9jbFid3BBewkwgPnCwpPht78AQ7uC9EnEux7q6dtVI'
    '-w7DmOMBcEA4PckI0EnAartZtc0xkJxcbtjno1GiJZkx6mTW0LiBmLdb4WwQHRB5-wLWvI'
    '1Moa7xLkNsfbfIor49K9VVjBUZXtDn3sk4GQOvFO3x6246y6eX-R8njYnr9H5CkCq60H3n'
    'wqFWl2oQmO9H9MdbYBl9a0L4mi4ioyC3oMvKhpfkAEoCFniobj-YHRk3skdjJ6vfBR1iwp'
    'pmdC_YvquJ78WYFg2dXZf6jBFPdt-HyyIRj7QC1Nx8gzDiHJncIPgOp7JSzoy_rs8ayCBh'
    'ZGGIfG7HiQHytLDNtKJ_kgYhawZSlEnDZZ1Or7lX_scCKWbgbEW8MFfpsX3J43HDiFklfZ'
    'QQwNa-gjdevoVlRFPbVK5JlPnPcwhNcDqXGJxKRaPNUHGMNBtxw5ujP-XcmGuJB9QO9pw5'
    '8o4_wr7p_LjLq5vHSdoEfwXzgQ7PoGzJ5tILpchJeI58_G_t0FaZMKIJxjEiHdQWdyrGm0'
    'jrIMtT4zU7yvxy-bWcQQOJN5tYMHFiZuO7XJbAUu1azeldjI7xdAqmkWT9EdaLS_L7274U'
    'Aogpyjzd0fQ3tj5fS_SP99261lGb7jN2OEJkywJGyqPMldT0WmRwXrtCb75JUQtFS7d415'
    'BcaW6CE9J6d5x1ieSjftyQzaQbjS2yVzE9pNWRIAoHpLMKlk7KWLEHweMl9do9xq1i4gIE'
    'qoumllNprS8WuaObdmP2JfKGf7hUSZUN39AF1NhOti2wh-N9idysDXO35vUT3EQwQcZru5'
    '1OW2UyE7a-Aa6V7XqCvb3ZDZHewS-2q7FW0EeJ_iz5Vi3l_CFiDXd522BFP6TusCniAcn_'
    'pw2snYhe6tT1UzJcJrcavvWACBj8_p26ducG8m_ScSrScGbDR58UUQcQgvz0H2UyOAIdM0'
    'M3uDX0WA1iImnDZHEVdrKVzV5jUU3JfDGWi2uWqnvYHdDAhT2I-TrnBJAyznjVOem-wNff'
    'RHgUv6zO7psfUtbFxG8bzlGF8THdN-1q98UYJ0uj13OecTprzz52a_GzgZPbGWJ4IC86A_'
    '9y9lA4og1fiyq1Ia35WfOrGjp1kmvbCga9nf6b3wBzYo6Z4T7h7iWxampuiIxo3FFUG91g'
    '8GRsv9EaATcTMvYy5oK97GY5KX2Q2CxzhKVIrXBnBNUVYLyHwOnP3b1AG1hMWa_jYZaE0g'
    'oMOX3CG4jmjQMS-lE35bhpK0-M-o0HqlZ7p2_fC3NyFYBfuV-TZLI7uOzwPXR0Op1bIRUe'
    'eYQG2lPi1nqlxiDCj31A9g5vR4R2kw833FXDD2h0mnp-j5O79AmLS7yEmUFJ9gIfG5wAAA'
    'AAAAAAAAAAAAAAAAAAAAAAABQoOFhoj"}}';

/// The seed of the test pyramid's first power key: public on purpose (the
/// test pyramid certifies nothing), the SHA-256 of
/// `zen-pyramid-test-power`.
const String kZenTestPowerSeed = 'trs85OtfN-iaTxdtlOqW7ID8sSQLYiX6kFicLo0Wf9I=';

/// The test pin in a debug or profile build, also when the original
/// pyramid is pinned.
const bool kZenPyramidTestPin = bool.fromEnvironment('ZEN_PYRAMID_TEST');

/// The pinned pyramid: its genesis record, and for the test pyramid the
/// seed of its first power key (anyone may found it).
@immutable
final class PyramidRoot {
  const PyramidRoot._(this.genesis, this.powerSeed);

  /// [json] as a pinned genesis record, or null when it is not one.
  static PyramidRoot? parse(String json, {Uint8List? powerSeed}) {
    if (json.isEmpty) {
      return null;
    }
    try {
      final PyramidRecord? r = PyramidRecord.fromJson(jsonDecode(json));
      // The original pyramid's genesis names its power key's ML-DSA half
      // too (`pq`), so the power key is anchored post-quantum from the
      // start; the test pyramid's key is public and needs none.
      if (r == null ||
          r.type != PyrT.genesis ||
          !PyramidRecord.isCanonicalKey(r.body['pk']) ||
          (powerSeed == null && !PyramidRecord.isCanonicalKey(r.body['pq']))) {
        return null;
      }
      return PyramidRoot._(r, powerSeed);
    } on Object {
      return null;
    }
  }

  final PyramidRecord genesis;

  /// The first power key's seed, known only for the test pyramid.
  final Uint8List? powerSeed;

  /// The pyramid's id: the hash of its genesis.
  String get id => genesis.id;

  /// The first power key (public).
  String get powerKey => genesis.str('pk');

  String get name => genesis.str('name');
}

/// The test pyramid.
final PyramidRoot kZenTestPyramidRoot = PyramidRoot.parse(
  kZenTestPyramidGenesis,
  powerSeed: unb64(kZenTestPowerSeed, length: 32),
)!;

/// The pyramid this app keeps: the original one, except the test one in
/// `flutter test` runs and in debug builds with [kZenPyramidTestPin]
/// (a release build always keeps the original).
PyramidRoot? get zenPyramidRoot {
  final PyramidRoot? pinned = PyramidRoot.parse(kZenPyramidGenesis);
  if (kReleaseMode) {
    return pinned;
  }
  final bool test =
      kZenPyramidTestPin || Platform.environment.containsKey('FLUTTER_TEST');
  return test || pinned == null ? kZenTestPyramidRoot : pinned;
}
