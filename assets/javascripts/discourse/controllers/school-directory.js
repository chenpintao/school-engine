import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";

// 搜索词写入 URL query param：从结果页点进个人主页后返回时，
// 浏览器恢复 ?q= 参数，组件据此自动重新搜索，无需重新输入
export default class SchoolDirectoryController extends Controller {
  queryParams = ["q"];

  @tracked q = "";
}
