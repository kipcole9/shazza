import Config

# Where new tensors live by default.
config :nx, default_backend: EXLA.Backend

# **The compiler used for every `defn` invocation.** Without this, defn
# falls through to `Nx.Defn.Evaluator` (the slow interpreter), which is
# what makes the chunked pipeline run far below its potential — every
# call into NxSignal.stft, Nx.window_max, Nx.fft, Nx.top_k etc. ends up
# interpreted instead of jitted. Setting `compiler: EXLA` jit-compiles
# each unique tensor shape once and reuses the program forever; with the
# fixed-shape chunked pipeline that means **one** compile per BEAM
# session no matter how many tracks are ingested.
config :nx, :default_defn_options, compiler: EXLA

config :shazza,
  # Audio pipeline
  sample_rate: 8_000,
  channels: 1,

  # STFT
  window_size: 1024,
  hop_size: 256,

  # Peak picking — target peaks-per-second density via adaptive threshold.
  peak_neighborhood: {21, 21},
  peak_density_per_second: 30,

  # Constellation hashing
  fan_out: 5,
  target_zone_min_dt: 1,
  target_zone_max_dt: 100,
  target_zone_max_df: 200,

  # Storage
  index_store: Shazza.Index.EtsStore
