import { ElNotification } from "element-plus";

/** 成功提示：右下角通知，3 秒后自动关闭 */
export function notifySuccess(message: string) {
  ElNotification({
    title: "成功",
    message,
    type: "success",
    position: "bottom-right",
    duration: 3000
  });
}

/** 失败提示：右下角通知，常驻需手动关闭（showClose 关闭按钮） */
export function notifyError(message: string) {
  ElNotification({
    title: "操作失败",
    message,
    type: "error",
    position: "bottom-right",
    duration: 0,
    showClose: true
  });
}

/** 警告提示：右下角通知，5 秒后自动关闭 */
export function notifyWarning(message: string) {
  ElNotification({
    title: "提示",
    message,
    type: "warning",
    position: "bottom-right",
    duration: 5000,
    showClose: true
  });
}
