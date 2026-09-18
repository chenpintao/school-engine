# frozen_string_literal: true

module SchoolEngine
  # 真实姓名 → 拼音首字母（如 "张三" → "zs"），纯 Ruby 自包含实现，无外部依赖。
  # 仅用于同学录"找人"检索：结果随学籍信息存入隐藏 custom field，不对前台输出真实姓名。
  #
  # 原理：GBK 编码按拼音读音排序，取每个读音在 GBK 有序区间的首字做 26 分界
  # （I/U/V 无对应汉字读音），对单字 GBK 双字节值二分即可得到首字母。
  # 覆盖 GB2312 常用汉字（姓名用字），生僻字/非汉字返回空串。
  module Pinyin
    # 读音分界首字（GBK 升序）：[字母, 该读音区间首字]
    BOUNDARY_CHARS = %w[
      阿 芭 擦 搭 蛾 发 噶 哈 击 喀 垃 妈 拿 哦 啪 期 然 撒 塌 挖 昔 压 匝
    ].freeze
    BOUNDARY_LETTERS = %w[A B C D E F G H J K L M N O P Q R S T W X Y Z].freeze

    BOUNDARIES =
      BOUNDARY_LETTERS.zip(
        BOUNDARY_CHARS.map { |ch| ch.encode("GBK").bytes }
      ).freeze

    class << self
      # 完整姓名 → 小写首字母串；保留其中的拉丁字母，忽略其他非汉字字符
      def initials(name)
        return "" if name.nil? || name.to_s.empty?
        name.to_s.each_char.map { |ch| initial(ch) }.join.gsub(/[^a-z]/, "")
      end

      # 单字 → 小写首字母；拉丁字母原样小写返回，其余无法识别返回 ""
      def initial(char)
        return char.downcase if char.ascii_only? && char.match?(/[A-Za-z]/)

        bytes = char.encode("GBK").bytes
        # GBK 汉字双字节且首字节 >= 0xB0（一级/二级汉字区）
        return "" unless bytes.length == 2 && bytes[0] >= 0xB0

        letter = ""
        lo = 0
        hi = BOUNDARIES.length - 1
        while lo <= hi
          mid = (lo + hi) / 2
          if (BOUNDARIES[mid][1] <=> bytes) <= 0
            letter = BOUNDARIES[mid][0]
            lo = mid + 1
          else
            hi = mid - 1
          end
        end
        letter.downcase
      rescue EncodingError
        ""
      end
    end
  end
end
