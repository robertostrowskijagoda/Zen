import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';

/// The genesis record of the original pyramid, pinned in the app: its id
/// (the hash of its signed content) is the pyramid's id, so no other
/// pyramid can pass for it. Phones keep and pass on only its records.
///
/// Made once with `dart run tool/zen_pyramid.dart genesis` (it also makes
/// the first power key, kept by the founder); empty until then — the
/// pyramid is not open yet.
const String kZenPyramidGenesis = '';

/// The genesis of the test pyramid (tests, the simulator, debug builds
/// while [kZenPyramidGenesis] is empty or with
/// `--dart-define=ZEN_PYRAMID_TEST=true`). A release build never uses it.
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

/// The pyramid this app keeps: the original one in a release build (none
/// until it is pinned), the test one in tests and in debug builds without
/// a pin or with [kZenPyramidTestPin].
PyramidRoot? get zenPyramidRoot {
  final PyramidRoot? pinned = PyramidRoot.parse(kZenPyramidGenesis);
  if (kReleaseMode) {
    return pinned;
  }
  return kZenPyramidTestPin || pinned == null ? kZenTestPyramidRoot : pinned;
}
