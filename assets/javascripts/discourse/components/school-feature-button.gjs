import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

/**
 * staff 精选/取消精选回帖（post menu 按钮，新版 glimmer post menu DAG）。
 * 可见条件：精选功能开启 + staff + optional 可选匿名分类 + 回帖（post_number > 1）。
 * 精选状态来自 PostSerializer 的 school_featured 字段。
 */
const FALLBACK_RULES = [
  { slug: "confess", mode: "optional" },
  { slug: "anonymous-wall", mode: "forced" },
];

const parseRuleLines = (lines) =>
  (Array.isArray(lines) ? lines : String(lines || "").split("\n"))
    .map((line) => {
      const [slug, mode] = line.split(":");
      return { slug: slug?.trim(), mode: mode?.trim() };
    })
    .filter((rule) => rule.slug && ["forced", "optional", "disabled"].includes(rule.mode));

export default class SchoolFeatureButton extends Component {
  @service currentUser;
  @service site;
  @service siteSettings;
  @tracked saving = false;

  get rules() {
    const parsed = parseRuleLines(this.siteSettings.school_engine_category_rules);
    return parsed.length ? parsed : FALLBACK_RULES;
  }

  get visible() {
    const post = this.args.post;
    if (!this.siteSettings.school_engine_feature_enabled) return false;
    if (!this.currentUser?.staff || !post || post.post_number <= 1) {
      return false;
    }
    const categoryId = post.topic?.category_id;
    const category = this.site.categories?.findBy?.("id", categoryId);
    return !!category &&
      this.rules.some((rule) => rule.slug === category.slug && rule.mode === "optional");
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
