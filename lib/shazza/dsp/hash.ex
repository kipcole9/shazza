defmodule Shazza.DSP.Hash do
  @moduledoc """
  Pack/unpack a constellation hash into a 32-bit integer.

  Layout (LSB → MSB):

    * 9 bits — `f1` (anchor frequency bin, 0..511)
    * 9 bits — `f2` (target frequency bin, 0..511)
    * 14 bits — `dt` (frame distance, 0..16383)

  The 9-bit field comfortably fits the bin range we need at an 8 kHz sample
  rate with a 1024-point FFT (513 bins). The 14-bit `dt` field allows up to
  ~16k frames between anchor and target; we cap target zones well below
  this in `Shazza.DSP.Constellation`.
  """

  import Bitwise

  @f_bits 9
  @dt_bits 14
  @f_mask (1 <<< @f_bits) - 1
  @dt_mask (1 <<< @dt_bits) - 1

  @spec pack(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def pack(f1, f2, dt)
      when f1 >= 0 and f1 <= @f_mask and
             f2 >= 0 and f2 <= @f_mask and
             dt >= 0 and dt <= @dt_mask do
    (dt <<< (2 * @f_bits)) ||| (f2 <<< @f_bits) ||| f1
  end

  @spec unpack(non_neg_integer()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def unpack(hash) do
    f1 = hash &&& @f_mask
    f2 = (hash >>> @f_bits) &&& @f_mask
    dt = (hash >>> (2 * @f_bits)) &&& @dt_mask
    {f1, f2, dt}
  end
end
