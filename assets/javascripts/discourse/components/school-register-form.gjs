import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { Input } from "@ember/component";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import DButton from "discourse/ui-kit/d-button";
import { and, eq, gt, lt, not } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

/**
 * 自定义注册向导（6 步：身份 → 账号 → 学籍 → 确认 → 实名 → 欢迎）。
 * 邮箱不验证，注册后直接激活并自动加入班级圈。
 */
export default class SchoolRegisterForm extends Component {
  @service siteSettings;

  @tracked step = 1;
  @tracked identity = "student";
  @tracked submitting = false;
  @tracked error = null;
  @tracked registered = false;
  // 注册成功后服务端返回的用户名（服务端已 log_on_user 下发会话 cookie）
  @tracked registeredUsername = "";

  // 账号字段
  @tracked email = "";
  @tracked username = "";
  @tracked password = "";
  @tracked password2 = "";

  // 学籍字段（学生）
  @tracked graduationYear = "";
  @tracked enrollmentYear = "";
  @tracked className = "";

  // 教师字段
  @tracked teacherName = "";
  @tracked teacherId = "";

  // 实名
  @tracked realName = "";

  get minPasswordLength() {
    // 与后端 register_user 一致：SiteSetting.min_password_length
    return parseInt(this.siteSettings.min_password_length, 10) || 8;
  }

  get passwordHint() {
    return i18n("school_engine.password_hint", { count: this.minPasswordLength });
  }

  get nowYear() {
    return new Date().getFullYear();
  }

  get isStudent() {
    return this.identity === "student";
  }

  get stepIndex() {
    return this.step - 1;
  }

  get steps() {
    return [
      { num: 1, label: i18n("school_engine.step_identity") },
      { num: 2, label: i18n("school_engine.step_account") },
      { num: 3, label: i18n("school_engine.step_enrollment") },
      { num: 4, label: i18n("school_engine.step_confirm") },
      { num: 5, label: i18n("school_engine.step_realname") },
    ];
  }

  // 年份/班级选项
  get gyOptions() {
    const arr = [];
    for (let y = this.nowYear + 9; y >= 2021; y--) arr.push(String(y));
    return arr;
  }
  get eyOptions() {
    const arr = [];
    for (let y = this.nowYear; y >= 2012; y--) arr.push(String(y));
    return arr;
  }
  get classOptions() {
    return ["1班", "2班", "3班", "4班", "5班", "6班"];
  }

  get confirmRows() {
    const rows = [
      [i18n("school_engine.email"), this.email],
      [i18n("school_engine.username"), this.username],
    ];
    if (this.isStudent) {
      rows.push([i18n("school_engine.graduation_year"), this.graduationYear + " 届"]);
      rows.push([i18n("school_engine.enrollment_year"), this.enrollmentYear + " 年"]);
      rows.push([i18n("school_engine.class_name"), this.className]);
    } else {
      rows.push([i18n("school_engine.teacher_name"), this.teacherName]);
    }
    return rows;
  }

  // ---- 年份联动：填一个自动算另一个（6+3 学制）----
  @action
  gyChanged(event) {
    this.graduationYear = event.target.value;
    if (this.graduationYear) {
      this.enrollmentYear = String(parseInt(this.graduationYear, 10) - 9);
    }
  }

  @action
  eyChanged(event) {
    this.enrollmentYear = event.target.value;
    if (this.enrollmentYear) {
      this.graduationYear = String(parseInt(this.enrollmentYear, 10) + 9);
    }
  }

  @action
  classChanged(event) {
    this.className = event.target.value;
  }

  @action
  selectIdentity(id) {
    this.identity = id;
  }

  // 步骤条点击回退（仅提交前允许回到已走过的步骤）
  @action
  jumpTo(index) {
    if (this.step <= 4 && index < this.stepIndex) {
      this.step = index + 1;
      this.error = null;
    }
  }

  @action
  next() {
    this.error = null;
    if (this.step === 2) {
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(this.email)) {
        this.error = i18n("school_engine.err_email_format");
        return;
      }
      if (this.username.length < 3 || this.username.length > 20) {
        this.error = i18n("school_engine.err_username_length");
        return;
      }
      if (this.password.length < this.minPasswordLength) {
        this.error = i18n("school_engine.err_password_short", {
          count: this.minPasswordLength,
        });
        return;
      }
      if (this.password !== this.password2) {
        this.error = i18n("school_engine.err_password_mismatch");
        return;
      }
    } else if (this.step === 3) {
      if (this.isStudent) {
        if (!this.graduationYear) {
          this.error = i18n("school_engine.err_choose_year");
          return;
        }
        if (!this.className) {
          this.error = i18n("school_engine.err_choose_class");
          return;
        }
      } else if (!this.teacherName.trim()) {
        this.error = i18n("school_engine.err_teacher_name");
        return;
      }
    }
    this.step = this.step + 1;
  }

  @action
  prev() {
    if (this.step > 1) {
      this.step = this.step - 1;
    }
  }

  // 提交注册（Step 4 确认页）
  @action
  submitRegister() {
    // 幂等：账号已创建时直接跳到实名/欢迎页（防止回退后重复提交）
    if (this.registered) {
      this.step = this.isStudent ? 5 : 6;
      return;
    }
    this.error = null;
    this.submitting = true;
    const body = {
      identity: this.identity,
      email: this.email.trim(),
      username: this.username.trim(),
      password: this.password,
    };
    if (this.isStudent) {
      body.graduation_year = parseInt(this.graduationYear, 10);
      body.enrollment_year = parseInt(this.enrollmentYear, 10);
      body.class_name = this.className;
    } else {
      body.teacher_name = this.teacherName.trim();
      body.teacher_id_last4 = this.teacherId.trim();
    }
    ajax("/school/register.json", { type: "POST", data: body })
      .then((data) => {
        this.submitting = false;
        this.registered = true;
        this.registeredUsername = data.username || "";
        if (this.isStudent) {
          this.step = 5; // 学生进入实名步骤（账号已创建并自动登录）
        } else {
          this.step = 6; // 教师已填实名，直接欢迎页
        }
      })
      .catch((e) => {
        this.submitting = false;
        this.error = (e.jqXHR?.responseJSON?.errors || []).join("；") || e.message;
      });
  }

  // 学生实名提交（Step 5）
  @action
  submitRealName() {
    this.error = null;
    if (!this.realName.trim()) {
      this.error = i18n("school_engine.err_realname");
      return;
    }
    this.submitting = true;
    ajax("/school/complete.json", {
      type: "POST",
      data: {
        real_name: this.realName.trim(),
      },
    })
      .then(() => {
        this.submitting = false;
        this.step = 6;
      })
      .catch((e) => {
        this.submitting = false;
        this.error = (e.jqXHR?.responseJSON?.errors || []).join("；") || e.message;
      });
  }

  @action
  goProfile() {
    // 整页跳转：让 Ember 重新引导并识别 register 阶段下发的登录会话，
    // 落到 DC 原生个人资料页（插件的资料/改密码嵌入都挂在该页）。
    const username = this.registeredUsername || this.username.trim();
    window.location.href = username
      ? `/u/${username}/preferences/profile`
      : "/school/profile";
  }

  @action
  goHome() {
    window.location.href = "/";
  }

  <template>
    <div class="school-auth-page">
      {{#if this.error}}
        <div class="school-auth-error">{{this.error}}</div>
      {{/if}}

      {{#if (eq this.step 6)}}
        {{! 欢迎页 }}
        <div class="school-welcome">
          <h1>{{i18n "school_engine.welcome_title"}}</h1>
          <p>{{i18n "school_engine.welcome_text"}}</p>
          <div class="school-welcome-guide">
            <h3>{{i18n "school_engine.welcome_guide_title"}}</h3>
            <p>{{i18n "school_engine.welcome_guide_text"}}</p>
            <DButton @label="school_engine.go_profile" @type="primary" @action={{this.goProfile}} />
          </div>
          <DButton @label="school_engine.later" @action={{this.goHome}} />
        </div>
      {{else}}
        {{! 步骤条 }}
        <div class="school-steps">
          {{#each this.steps as |s index|}}
            <div
              class="school-step {{if (lt index this.stepIndex) "done"}} {{if (eq index this.stepIndex) "active"}} {{if (and (lt this.step 5) (lt index this.stepIndex)) "clickable"}}"
              {{on "click" (fn this.jumpTo index)}}
            >
              <span class="school-step-num">{{s.num}}</span>
              <span class="school-step-label">{{s.label}}</span>
            </div>
          {{/each}}
        </div>

        {{#if (eq this.step 1)}}
          <h2>{{i18n "school_engine.identity_student"}} / {{i18n "school_engine.identity_teacher"}}</h2>
          <div class="school-identity-grid">
            <button type="button" class="school-identity-card {{if this.isStudent "selected"}}" {{on "click" (fn this.selectIdentity "student")}}>
              <span class="school-identity-icon">🎓</span>
              <span>{{i18n "school_engine.identity_student"}}</span>
              <small>{{i18n "school_engine.identity_student_desc"}}</small>
            </button>
            <button type="button" class="school-identity-card {{if (not this.isStudent) "selected"}}" {{on "click" (fn this.selectIdentity "teacher")}}>
              <span class="school-identity-icon">👨‍🏫</span>
              <span>{{i18n "school_engine.identity_teacher"}}</span>
              <small>{{i18n "school_engine.identity_teacher_desc"}}</small>
            </button>
          </div>
        {{/if}}

        {{#if (eq this.step 2)}}
          <div class="school-field">
            <label>{{i18n "school_engine.email"}}</label>
            <Input @type="email" @value={{this.email}} placeholder="your@example.com" autocomplete="email" />
            <p class="school-hint">{{i18n "school_engine.email_hint"}}</p>
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.username"}}</label>
            <Input @type="text" @value={{this.username}} autocomplete="username" />
            <p class="school-hint">{{i18n "school_engine.username_hint"}}</p>
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.password"}}</label>
            <Input @type="password" @value={{this.password}} autocomplete="new-password" />
            <p class="school-hint">{{this.passwordHint}}</p>
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.confirm_password"}}</label>
            <Input @type="password" @value={{this.password2}} autocomplete="new-password" />
          </div>
        {{/if}}

        {{#if (eq this.step 3)}}
          {{#if this.isStudent}}
            <div class="school-field">
              <label>{{i18n "school_engine.graduation_year"}} / {{i18n "school_engine.enrollment_year"}} <span class="school-hint-inline">{{i18n "school_engine.year_link_hint"}}</span></label>
              <div class="school-row2">
                <select value={{this.graduationYear}} {{on "change" this.gyChanged}}>
                  <option value="">{{i18n "school_engine.graduation_year"}}</option>
                  {{#each this.gyOptions as |opt|}}
                    <option value={{opt}} selected={{eq this.graduationYear opt}}>{{opt}} 届</option>
                  {{/each}}
                </select>
                <select value={{this.enrollmentYear}} {{on "change" this.eyChanged}}>
                  <option value="">{{i18n "school_engine.enrollment_year"}}</option>
                  {{#each this.eyOptions as |opt|}}
                    <option value={{opt}} selected={{eq this.enrollmentYear opt}}>{{opt}} 年</option>
                  {{/each}}
                </select>
              </div>
            </div>
            <div class="school-field">
              <label>{{i18n "school_engine.class_name"}}</label>
              <select value={{this.className}} {{on "change" this.classChanged}}>
                <option value="">{{i18n "school_engine.class_name"}}</option>
                {{#each this.classOptions as |opt|}}
                  <option value={{opt}} selected={{eq this.className opt}}>{{opt}}</option>
                {{/each}}
              </select>
            </div>
          {{else}}
            <div class="school-field">
              <label>{{i18n "school_engine.teacher_name"}}</label>
              <Input @type="text" @value={{this.teacherName}} />
            </div>
            <div class="school-field">
              <label>{{i18n "school_engine.teacher_id"}}</label>
              <Input @type="text" @value={{this.teacherId}} maxlength="4" />
              <p class="school-hint">{{i18n "school_engine.teacher_id_hint"}}</p>
            </div>
          {{/if}}
        {{/if}}

        {{#if (eq this.step 4)}}
          <h2>{{i18n "school_engine.confirm_title"}}</h2>
          <div class="school-confirm-list">
            {{#each this.confirmRows as |row|}}
              <div class="school-confirm-row">
                <span class="school-confirm-k">{{row.[0]}}</span>
                <span class="school-confirm-v">{{row.[1]}}</span>
              </div>
            {{/each}}
          </div>
          <div class="school-warning">{{i18n "school_engine.confirm_warning"}}</div>
          <DButton @label="school_engine.submit" @type="primary" @action={{this.submitRegister}} @isLoading={{this.submitting}} />
        {{/if}}

        {{#if (eq this.step 5)}}
          <div class="school-field">
            <label>{{i18n "school_engine.real_name"}}</label>
            <Input @type="text" @value={{this.realName}} />
            <p class="school-hint">{{i18n "school_engine.real_name_hint"}}</p>
          </div>
          <DButton @label="school_engine.submit_realname" @type="primary" @action={{this.submitRealName}} @isLoading={{this.submitting}} />
        {{/if}}

        {{#if (lt this.stepIndex 3)}}
          <DButton @label="school_engine.next" @type="primary" @action={{this.next}} class="school-next-btn" />
        {{/if}}
        {{#if (gt this.step 1)}}
          {{#if (lt this.step 4)}}
            <DButton @label="school_engine.prev" @action={{this.prev}} class="school-prev-btn" />
          {{/if}}
        {{/if}}
      {{/if}}
    </div>
  </template>
}
