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
  doLogin() {
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
      .then(() => {
        this.submitting = false;
        window.location.href = "/";
      })
      .catch(() => {
        this.submitting = false;
        this.error = i18n("school_engine.err_login");
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

      <div class="school-field">
        <label>{{i18n "school_engine.username"}}</label>
        <Input @type="text" @value={{this.loginName}} autocomplete="username" />
      </div>
      <div class="school-field">
        <label>{{i18n "school_engine.password"}}</label>
        <Input @type="password" @value={{this.password}} autocomplete="current-password" />
      </div>

      <DButton @label="school_engine.login" @type="primary" @action={{this.doLogin}} @isLoading={{this.submitting}} class="school-submit-btn" />

      <p class="school-switch">
        <a href="#" {{on "click" this.goRegister}}>{{i18n "school_engine.no_account"}}</a>
      </p>
    </div>
  </template>
}
