defmodule TickmarkWeb.GettextKoTest do
  use ExUnit.Case, async: true

  alias TickmarkWeb.CoreComponents

  test "Ecto 기본 검증과 사용자 정의 오류를 한국어로 번역한다" do
    Gettext.with_locale(TickmarkWeb.Gettext, "ko", fn ->
      assert CoreComponents.translate_error({"can't be blank", []}) == "필수 입력 항목입니다."

      assert CoreComponents.translate_error({"has already been taken", []}) == "이미 사용 중입니다."

      assert CoreComponents.translate_error({"must have the @ sign and no spaces", []}) ==
               "공백 없이 @를 포함한 이메일을 입력하세요."

      assert CoreComponents.translate_error({"does not match password", []}) ==
               "비밀번호가 일치하지 않습니다."

      assert CoreComponents.translate_error({"did not change", []}) == "기존 값과 같습니다."
    end)
  end

  test "한국어 복수형은 수와 무관하게 하나의 번역을 쓰고 count를 보간한다" do
    Gettext.with_locale(TickmarkWeb.Gettext, "ko", fn ->
      for count <- [1, 12] do
        assert CoreComponents.translate_error(
                 {"should be at least %{count} character(s)", [count: count]}
               ) == "#{count}자 이상이어야 합니다."
      end
    end)
  end

  test "공통 작업과 닫기 문구를 한국어로 번역한다" do
    Gettext.with_locale(TickmarkWeb.Gettext, "ko", fn ->
      assert Gettext.gettext(TickmarkWeb.Gettext, "close") == "닫기"
      assert Gettext.gettext(TickmarkWeb.Gettext, "Actions") == "작업"
    end)
  end
end
