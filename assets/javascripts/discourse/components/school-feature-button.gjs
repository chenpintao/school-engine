import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

/**
 * staff 精选/取消精选帖子（post menu 按钮，新版 glimmer post menu DAG）。
 * 可见条件：精选功能开启 + staff + 普通话题（含首楼 OP）。
 * 任意板块均可精选，不限匿名表达板块；私信话题不显示。
 * 精选状态来自 PostSerializer 的 school_featured 字段。
 */
export default class SchoolFeatureButton extends Component {
  @service currentUser;
  @service siteSettings;
  @tracked saving = false;

  get visible() {
    const post = this.args.post;
    if (!this.siteSettings.school_engine_feature_enabled) return false;
    if (!this.currentUser?.staff || !post) {
      return false;
    }
    return post.topic?.archetype !== "private_message";
  }

  get featured() {
    return this.args.post?.school_featured === true;
  }

  @action
  async toggle() {
    if (this.saving) return;
    this.saving = true;
    const post = this.args.post;
    const url = this.featured ? "/school/unfeature-post" : "/school/feature-post";
    try {
      await ajax(url, { type: "POST", data: { post_id: post.id } });
      post.set("school_featured", !this.featured);
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  <template>
    {{#if this.visible}}
      <DButton
        class="post-action-menu__school-feature {{if this.featured 'is-featured'}}"
        @action={{this.toggle}}
        @icon={{if this.featured "star" "far-star"}}
        @title={{if
          this.featured
          (i18n "school_engine.feature_unfeature")
          (i18n "school_engine.feature_title")
        }}
        @isLoading={{this.saving}}
      />
    {{/if}}
  </template>
}
