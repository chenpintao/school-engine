import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { Input } from "@ember/component";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

/**
 * 自定义登录页：复用 Discourse 原生 POST /session 接口，样式由插件 SCSS 控制。
 */
export default class SchoolLoginForm extends Component {
  @service router;

  @tracked loginName = "";
  @tracked password = "";
  @tracked error = null;
  @tracked submitting = false;

  @action
  onEnterKey(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      event.target.closest("form").requestSubmit();
    }
  }

  @action
  doLogin(event) {
    event?.preventDefault?.();
    this.error = null;
    if (!this.loginName.trim() || !this.password) {
      this.error = i18n("school_engine.err_login");
      return;
    }
    this.submitting = true;
    ajax("/session", {
      type: "POST",
      data: { login: this.loginName.trim(), password: this.password },
    })
      .then((result) => {
        this.submitting = false;
        // 注意：DC 的 POST /session 登录失败（密码错/未激活/被暂停/未审批）
        // 同样返回 HTTP 200，仅在响应体里带 error，此时并未下发 _t cookie。
        // 只看状态码会"假登录"：跳转后仍是匿名状态，必须检查响应体。
        if (result?.error) {
          this.error = result.error;
          return;
        }
        // 需要二次验证（2FA/安全密钥）时同样不会建立会话，不能直接跳转
        if (result?.second_factor_required || result?.security_key_required) {
          this.error = i18n("school_engine.err_second_factor");
          return;
        }
        // 仅在服务端确认真正登录成功时才跳转，DC 会随响应下发 _t cookie
        window.location.href = "/";
      })
      .catch((e) => {
        this.submitting = false;
        // 429 限流、403（本地登录关闭）等非 200 响应，尽量展示服务端文案
        this.error = e.jqXHR?.responseJSON?.error || i18n("school_engine.err_login");
      });
  }

  @action
  goRegister() {
    this.router.transitionTo("school-register");
  }

  <template>
    <div class="school-auth-page">
      {{#if this.error}}
        <div class="school-auth-error">{{this.error}}</div>
      {{/if}}

      <h2>{{i18n "school_engine.login_title"}}</h2>
      <p class="school-subtitle">{{i18n "school_engine.login_subtitle"}}</p>

      <form {{on "submit" this.doLogin}}>
        <div class="school-field">
          <label>{{i18n "school_engine.username"}}</label>
          <Input @type="text" @value={{this.loginName}} autocomplete="username" {{on "keydown" this.onEnterKey}} />
        </div>
        <div class="school-field">
          <label>{{i18n "school_engine.password"}}</label>
          <Input @type="password" @value={{this.password}} autocomplete="current-password" {{on "keydown" this.onEnterKey}} />
        </div>

        <DButton @label="school_engine.login" @type="primary" @buttonType="submit" @isLoading={{this.submitting}} class="school-submit-btn" />
      </form>

      <p class="school-switch">
        <a href="#" {{on "click" this.goRegister}}>{{i18n "school_engine.no_account"}}</a>
      </p>
    </div>
  </template>
}
